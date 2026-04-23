{-# LANGUAGE OverloadedStrings #-}

-- | WASI reactor entry: read Conway tx hex on stdin, write JSON on stdout.
--   Error category on stderr, non-zero exit, no partial JSON on stdout.
module Main (main) where

import qualified Conway.Inspector       as Inspector
import qualified Data.Aeson             as Aeson
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import qualified Data.ByteString.Lazy   as BSL
import           System.Exit            (exitFailure, exitSuccess)
import           System.IO              (hPutStrLn, stderr, stdout)

main :: IO ()
main = do
    input <- BS.getContents
    case Inspector.inspect (stripNewlines input) of
        Left (Inspector.MalformedHex err) -> die "malformed_hex" err
        Left (Inspector.MalformedCbor err) -> die "malformed_cbor" err
        Right value -> do
            BSL.hPut stdout (Aeson.encode value)
            BSL.hPut stdout "\n"
            exitSuccess
  where
    stripNewlines = BS.filter (\c -> c /= 0x0a && c /= 0x0d && c /= 0x20 && c /= 0x09)

    die category detail = do
        hPutStrLn stderr (category <> ": " <> detail)
        exitFailure
