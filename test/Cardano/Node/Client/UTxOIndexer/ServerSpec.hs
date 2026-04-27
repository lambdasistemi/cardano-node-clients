{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.ServerSpec
Description : NDJSON Unix-socket server round-trip
License     : Apache-2.0

Spins up the server on a temp-dir Unix socket, connects
as a client, and exercises both request kinds:

* @{"utxos_at": "<hex>"}@ → JSON list of UTxO entries.
* @{"ready": null}@ → readiness JSON.
-}
module Cardano.Node.Client.UTxOIndexer.ServerSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    Socket,
    SocketType (Stream),
    close,
    connect,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import System.Directory (createDirectoryIfMissing, doesPathExist, removeFile)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer.Server" $ do
    it "ready endpoint returns the ReadyStatus we feed it" $
        withTestServer ready1 $ \sockPath -> do
            resp <- request sockPath "{\"ready\":null}\n"
            decodeReady resp `shouldBe` Just (True, Just 1234, Just 1230, Just 4)

    it "utxos_at returns an empty list when no UTxOs exist" $
        withTestServer ready1 $ \sockPath -> do
            let addrHex = Text.unpack (hex (BS.replicate 29 0xAA))
                req =
                    "{\"utxos_at\":\""
                        <> addrHex
                        <> "\"}\n"
            resp <- request sockPath (BS.pack (map (fromIntegral . fromEnum) req))
            decodeUtxos resp `shouldBe` Just []

    it "utxos_at returns previously-applied UTxOs at the address" $
        withInMemoryIndexer $ \idx -> do
            let addr = Address (BS.replicate 29 0xAA)
                txin = TxIn (BS.replicate 32 0x11) 0
                txout = TxOut "value-bytes-0"
            applyAtSlot idx (SlotNo 1) [UtxoCreate txin addr txout]
            withSystemTempDirectory "indexer-server" $ \dir -> do
                let sockPath = dir <> "/sock"
                tid <-
                    forkIO
                        (runServer sockPath idx (pure ready1))
                waitForFile sockPath
                let addrHex = Text.unpack (hex (BS.replicate 29 0xAA))
                    req =
                        "{\"utxos_at\":\""
                            <> addrHex
                            <> "\"}\n"
                resp <-
                    request
                        sockPath
                        (BS.pack (map (fromIntegral . fromEnum) req))
                killThread tid
                _ <- removeIfPresent sockPath
                decodeUtxos resp
                    `shouldSatisfy` ( \case
                                        Just [(t, _)] | t == "1111111111111111111111111111111111111111111111111111111111111111#0" -> True
                                        _ -> False
                                    )

    it "responds with a JSON error for malformed input" $
        withTestServer ready1 $ \sockPath -> do
            resp <- request sockPath "not json at all\n"
            Aeson.decodeStrict' resp
                `shouldSatisfy` ( \case
                                    Just (Aeson.Object o) ->
                                        KM.member (Key.fromText "error") o
                                    _ -> False
                                )

-- Test helpers --------------------------------------------------------

ready1 :: ReadyStatus
ready1 =
    ReadyStatus
        { rsReady = True
        , rsTipSlot = Just (SlotNo 1234)
        , rsProcessedSlot = Just (SlotNo 1230)
        , rsSlotsBehind = Just 4
        }

{- | Spin up an in-memory indexer + server on a tempdir
Unix socket, run the action, then kill the server.
-}
withTestServer ::
    ReadyStatus ->
    (FilePath -> IO a) ->
    IO a
withTestServer rs action =
    withInMemoryIndexer $ \idx ->
        withSystemTempDirectory "indexer-server" $ \dir -> do
            let sockPath = dir <> "/sock"
            createDirectoryIfMissing True dir
            bracket
                (forkIO (runServer sockPath idx (pure rs)))
                ( \tid -> do
                    killThread tid
                    _ <- removeIfPresent sockPath
                    pure ()
                )
                ( \_ -> do
                    waitForFile sockPath
                    action sockPath
                )

-- | Poll up to 2 s for the server to bind its socket.
waitForFile :: FilePath -> IO ()
waitForFile path = go (200 :: Int)
  where
    go 0 = error ("waitForFile: socket never appeared at " <> path)
    go n = do
        present <- doesPathExist path
        if present
            then pure ()
            else threadDelay 10_000 >> go (n - 1)

removeIfPresent :: FilePath -> IO ()
removeIfPresent p = do
    r <- try (removeFile p) :: IO (Either IOError ())
    case r of
        Right () -> pure ()
        Left e
            | isDoesNotExistError e -> pure ()
            | otherwise -> ioError e

{- | Open a connection to @sockPath@, send @payload@,
read the response line, close.
-}
request :: FilePath -> BS.ByteString -> IO BS.ByteString
request sockPath payload =
    bracket connectClient close $ \s -> do
        Net.sendAll s payload
        recvAll s
  where
    connectClient :: IO Socket
    connectClient = do
        s <- socket AF_UNIX Stream 0
        connect s (SockAddrUnix sockPath)
        pure s
    recvAll s = go BS.empty
      where
        go acc = do
            chunk <- Net.recv s 4096
            if BS.null chunk
                then pure acc
                else go (acc <> chunk)

hex :: BS.ByteString -> Text.Text
hex = Text.decodeUtf8 . Base16.encode

decodeReady ::
    BS.ByteString ->
    Maybe (Bool, Maybe Integer, Maybe Integer, Maybe Integer)
decodeReady bs = do
    Aeson.Object o <- Aeson.decodeStrict' bs
    rd <- KM.lookup (Key.fromText "ready") o >>= asBool
    let tip = KM.lookup (Key.fromText "tipSlot") o >>= asInt
        proc' = KM.lookup (Key.fromText "processedSlot") o >>= asInt
        beh = KM.lookup (Key.fromText "slotsBehind") o >>= asInt
    pure (rd, tip, proc', beh)
  where
    asBool (Aeson.Bool b) = Just b
    asBool _ = Nothing
    asInt :: Aeson.Value -> Maybe Integer
    asInt (Aeson.Number n) = Just (round n)
    asInt _ = Nothing

{- | Decode a @{"utxos": [...]}@ response into
a list of @(txin-text, txout-hex-text)@ pairs.
-}
decodeUtxos ::
    BS.ByteString ->
    Maybe [(Text.Text, Text.Text)]
decodeUtxos bs = do
    Aeson.Object o <- Aeson.decodeStrict' bs
    Aeson.Array arr <- KM.lookup (Key.fromText "utxos") o
    traverse decodeEntry (foldr (:) [] arr)
  where
    decodeEntry (Aeson.Object o) = do
        Aeson.String txin <- KM.lookup (Key.fromText "txin") o
        Aeson.String txout <- KM.lookup (Key.fromText "txout") o
        pure (txin, txout)
    decodeEntry _ = Nothing
