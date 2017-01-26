{ mkDerivation, base, one-liner, opaleye, postgresql-simple
, product-profunctors, profunctors, scientific, stdenv, streaming
, tagged, text, exceptions, free, streaming-postgresql-simple
}:
mkDerivation {
  pname = "rel8";
  version = "0.1.0.0";
  src = ./.;
  libraryHaskellDepends = [
    base one-liner opaleye postgresql-simple product-profunctors
    profunctors scientific streaming tagged text exceptions free
    streaming-postgresql-simple
  ];
  license = stdenv.lib.licenses.bsd3;
}
