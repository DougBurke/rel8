{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Monad.Rel8 where

import Control.Monad.Trans.Resource (MonadResource)
import Control.Exception (fromException)
import Control.Monad.Catch (MonadMask, mask, try, throwM)
import Control.Monad.Free.Church (F, liftF, iterM)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Control.Monad.Trans.Reader
import Data.Int (Int64)
import qualified Database.PostgreSQL.Simple as Pg
import qualified Database.PostgreSQL.Simple.Transaction as Pg
import qualified Streaming.Prelude as S
import Opaleye (Query)

import Rel8.Internal
import Rel8.IO

--------------------------------------------------------------------------------
-- | Syntax tree for running individual statements against a database.

data StatementSyntax :: * -> * where
        Select ::
            Table pg haskell =>
            Query pg -> ([haskell] -> k) -> StatementSyntax k
        Insert1Returning ::
            BaseTable table =>
            (table Insert) -> (table QueryResult -> k) -> StatementSyntax k
        Insert ::
            BaseTable table =>
            [table Insert] -> (Int64 -> k) -> StatementSyntax k
        Update ::
            (BaseTable table, DBBool bool) =>
            (table Expr -> Expr bool) ->
            (table Expr -> table Expr) -> (Int64 -> k) -> StatementSyntax k
        Delete ::
            (BaseTable table, DBBool bool) =>
            (table Expr -> Expr bool) -> (Int64 -> k) -> StatementSyntax k

deriving instance Functor StatementSyntax

-- | The class of monads that can run database statements.
class Monad m => MonadStatement m where
  liftStatements :: F StatementSyntax a -> m a

instance {-# OVERLAPPABLE #-} (Monad (t m), MonadTrans t, MonadStatement m) => MonadStatement (t m) where
  liftStatements = lift . liftStatements

select
  :: (MonadStatement m, Table expr haskell)
  => Query expr -> m [haskell]
select q = liftStatements (liftF (Select q id))

insert1Returning
  :: ( MonadStatement m
     , BaseTable table
     )
  => (table Insert) -> m (table QueryResult)
insert1Returning row = liftStatements (liftF (Insert1Returning row id))

insert
  :: MonadStatement m
  => BaseTable table => [table Insert] -> m Int64
insert rows = liftStatements (liftF (Insert rows id))

update
  :: (MonadStatement m, BaseTable table)
  => (table Expr -> Expr Bool)
  -> (table Expr -> table Expr)
  -> m Int64
update f up = liftStatements (liftF (Update f up id))

delete :: (MonadStatement m, BaseTable table, DBBool bool)
       => (table Expr -> Expr bool)
       -> m Int64
delete f = liftStatements (liftF (Delete f id))

--------------------------------------------------------------------------------
-- | The class of monads that can perform a rollback, aborting a transaction.
class Monad m => MonadRollback e m | m -> e where
  abortTransaction :: e -> m a

--------------------------------------------------------------------------------
-- | The syntax of programs that can run transactions.
data TransactionSyntax e k =
  forall a.
  Statements Pg.TransactionMode
             (Pg.SqlError -> Bool)
             (forall m. (MonadStatement m, MonadRollback e m) => m a)
             (Either e a -> k)

deriving instance Functor (TransactionSyntax e)

-- | The class of monads that can run transactions.
class Monad m => MonadTransaction m where
  liftTransaction :: F (TransactionSyntax e) a -> m a

instance {-# OVERLAPPABLE #-} (Monad (t m), MonadTrans t, MonadTransaction m) => MonadTransaction (t m) where
  liftTransaction = lift . liftTransaction

runTransaction :: MonadTransaction m
               => Pg.TransactionMode
               -> (Pg.SqlError -> Bool)
               -> (forall n. (MonadStatement n, MonadRollback e n) => n a)
               -> m (Either e a)
runTransaction mode shouldRetry t =
  liftTransaction (liftF (Statements mode shouldRetry t id))

runSerializableTransaction
  :: MonadTransaction m
  => (forall n. (MonadStatement n, MonadRollback e n) => n a) -> m (Either e a)
runSerializableTransaction =
  runTransaction
    Pg.TransactionMode {Pg.isolationLevel = Pg.Serializable
                       ,Pg.readWriteMode = Pg.ReadWrite}
    Pg.isSerializationError

--------------------------------------------------------------------------------
newtype PostgreSQLTransactionT m a =
  PostgreSQLTransactionT (ReaderT Pg.Connection m a)
  deriving (Functor,Applicative,Monad)

instance (MonadIO m, MonadMask m, MonadResource m) =>
         MonadTransaction (PostgreSQLTransactionT m) where
  liftTransaction =
    PostgreSQLTransactionT .
    iterM
      (\(Statements mode shouldRetry t k) -> do
         pg <- ask
         out <-
           withTransactionModeRetry
             mode
             shouldRetry
             pg
             (do out <- runPostgreSQLStatements t pg
                 case out of
                   Left {} -> liftIO (Pg.rollback pg)
                   Right {} -> return ()
                 return out)
         k out)

-- | A handler that runs individual statements against a PostgreSQL connection.
-- Again, we just use a reader monad to pass the connection handle around.
newtype PostgreSQLStatementT e m a =
  PostgreSQLStatementT (ExceptT e (ReaderT Pg.Connection m) a)
  deriving (Functor,Applicative,Monad)

runPostgreSQLStatements
  :: PostgreSQLStatementT e m a -> Pg.Connection -> m (Either e a)
runPostgreSQLStatements (PostgreSQLStatementT r) = runReaderT (runExceptT r)

instance (MonadIO m, MonadMask m, MonadResource m) => MonadStatement (PostgreSQLStatementT e m) where
  liftStatements =
    PostgreSQLStatementT . ExceptT . fmap Right .
    iterM (\op ->
             do conn <- ask
                step conn op)
    where step pg (Select q k) = S.toList_ (Rel8.IO.select (Rel8.IO.stream pg) q) >>= k
          step pg (Insert1Returning q k) =
            liftIO (Rel8.IO.insert1Returning pg q) >>= k
          step pg (Insert q k) = liftIO (Rel8.IO.insert pg q) >>= k
          step pg (Update a b k) = liftIO (Rel8.IO.update pg a b) >>= k
          step pg (Delete q k) = liftIO (Rel8.IO.delete pg q) >>= k

instance (Monad m) => MonadRollback e (PostgreSQLStatementT e m) where
  abortTransaction l = PostgreSQLStatementT (ExceptT (return (Left l)))

runPostgreSQLTransactions
  :: PostgreSQLTransactionT m a -> Pg.Connection -> m a
runPostgreSQLTransactions (PostgreSQLTransactionT r) = runReaderT r

--------------------------------------------------------------------------------
withTransactionModeRetry :: (MonadMask m,MonadIO m)
                         => Pg.TransactionMode
                         -> (Pg.SqlError -> Bool)
                         -> Pg.Connection
                         -> m a
                         -> m a
withTransactionModeRetry mode shouldRetry conn act =
  mask $
  \restore ->
    retryLoop $
    try $
    do a <- restore act
       liftIO (Pg.commit conn)
       return a
  where retryLoop act' =
          do liftIO (Pg.beginMode mode conn)
             r <- act'
             case r of
               Left e ->
                 do liftIO (Pg.rollback conn)
                    case fmap shouldRetry (fromException e) of
                      Just True -> retryLoop act'
                      _ -> throwM e
               Right a -> return a
