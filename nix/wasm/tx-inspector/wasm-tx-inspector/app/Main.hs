{-# LANGUAGE OverloadedStrings #-}

{- | WASI reactor entry: read either raw Conway tx hex or a JSON RPC envelope
  on stdin, write JSON on stdout. Error category on stderr, non-zero exit,
  no partial JSON on stdout.
-}
module Main (main) where

import qualified Conway.Inspector as Inspector
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr, stdout)

main :: IO ()
main = do
    input <- BS.getContents
    case Inspector.rpc input of
        Left (Inspector.MalformedHex err) -> die "malformed_hex" err
        Left (Inspector.MalformedCbor err) -> die "malformed_cbor" err
        Left (Inspector.MalformedRpc err) -> die "malformed_rpc" err
        Left (Inspector.UnknownRpcMethod method) ->
            die "unknown_rpc_method" (T.unpack method)
        Right value -> do
            BSL.hPut stdout (Aeson.encode value)
            BSL.hPut stdout "\n"
            exitSuccess
  where
    die category detail = do
        hPutStrLn stderr (category <> ": " <> detail)
        exitFailure
