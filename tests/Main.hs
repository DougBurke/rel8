{-# language BlockArguments #-}
{-# language QuasiQuotes #-}
{-# language DisambiguateRecordFields #-}
{-# language OverloadedStrings #-}
{-# language RecordWildCards #-}
{-# language DeriveGeneric #-}
{-# language StandaloneDeriving #-}
{-# language DeriveAnyClass #-}
{-# language FlexibleInstances #-}
{-# language FlexibleContexts #-}

module Main where

import Data.List ( sort )
import GHC.Generics ( Generic )
import Control.Monad.Trans.Control ( MonadBaseControl, liftBaseOp_ )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Exception ( bracket, throwIO )
import Database.PostgreSQL.Simple ( Connection, connectPostgreSQL, close, withTransaction, execute_, executeMany, rollback )
import Database.PostgreSQL.Simple.SqlQQ ( sql )
import qualified Database.Postgres.Temp as TmpPostgres
import Hedgehog ( Property, property, (===), forAll, cover )
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Rel8
import Test.Tasty
import Test.Tasty.Hedgehog ( testProperty )


main :: IO ()
main = defaultMain tests


tests :: TestTree
tests =
  withResource startTestDatabase stopTestDatabase \getTestDatabase ->
  testGroup "rel8" [ testSelectTestTable getTestDatabase ]

  where

    startTestDatabase = do
      db <- TmpPostgres.start >>= either throwIO return

      bracket (connectPostgreSQL (TmpPostgres.toConnectionString db)) close \conn -> do
        execute_ conn [sql|
          CREATE TABLE test_table ( column1 text not null, column2 bool not null );
        |]

      return (db)

    stopTestDatabase = TmpPostgres.stop

databasePropertyTest :: TestName -> (IO Connection -> Property) -> IO TmpPostgres.DB -> TestTree
databasePropertyTest testName f getTestDatabase =
  withResource connect close $
  testProperty testName . f

  where

    connect = connectPostgreSQL . TmpPostgres.toConnectionString =<< getTestDatabase


data TestTable f = TestTable
  { testTableColumn1 :: Rel8.Column f String
  , testTableColumn2 :: Rel8.Column f Bool
  }
  deriving
    ( Generic, Rel8.HigherKindedTable )


deriving instance Eq (TestTable Rel8.Identity)
deriving instance Ord (TestTable Rel8.Identity)
deriving instance Show (TestTable Rel8.Identity)


testTableSchema :: Rel8.TableSchema ( TestTable Rel8.ColumnSchema )
testTableSchema =
  Rel8.TableSchema
    { tableName = "test_table"
    , tableSchema = Nothing
    , tableColumns = TestTable
        { testTableColumn1 = "column1"
        , testTableColumn2 = "column2"
        }
    }


testSelectTestTable :: IO TmpPostgres.DB -> TestTree
testSelectTestTable = databasePropertyTest "Can SELECT TestTable" \connect -> property do
  connection <- liftIO connect

  rows <- forAll do
    Gen.list (Range.linear 0 10) do
      testTableColumn1 <- Gen.list (Range.linear 0 20) Gen.alphaNum
      testTableColumn2 <- Gen.bool
      return TestTable{..}

  cover 1 "Empty" $ null rows
  cover 1 "Singleton" $ null $ drop 1 rows
  cover 1 ">1 row" $ not $ null $ drop 1 rows

  selected <- rollingBack connection do
    liftIO do
      executeMany connection
        [sql| INSERT INTO test_table (column1, column2) VALUES (?, ?) |]
        [ ( testTableColumn1, testTableColumn2 ) | TestTable{..} <- rows ]

    Rel8.select connection do
      Rel8.each testTableSchema

  sort selected === sort rows


rollingBack
  :: (MonadBaseControl IO m, MonadIO m)
  => Connection -> m a -> m a
rollingBack connection m =
  liftBaseOp_ (withTransaction connection) $ m <* liftIO (rollback connection)
