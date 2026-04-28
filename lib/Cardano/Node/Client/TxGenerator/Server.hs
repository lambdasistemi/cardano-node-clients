{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Server
Description : NDJSON Unix-socket control wire for the tx-generator
License     : Apache-2.0

Listens on a Unix domain socket and serves the
tx-generator daemon's control wire as newline-delimited
JSON. One request per connection, single response, then
EOF + close. Same idiom as
'Cardano.Node.Client.UTxOIndexer.Server' (#79).

The four request types are routed through 'ServerHooks',
which the daemon's 'Main' wires up. v1 (T006) ships only
the @ready@ and @snapshot@ hooks for real; @transact@
and @refill@ are stubbed as @{"ok":false,"reason":
"index-not-ready"}@ via 'stubHooks' until T008 / T011
fill them in.

Wire schemas live in
@specs/034-cardano-tx-generator/contracts/control-wire.md@.
-}
module Cardano.Node.Client.TxGenerator.Server (
    -- * Server
    runServer,

    -- * Hook record
    ServerHooks (..),
    stubHooks,
) where

import Cardano.Node.Client.TxGenerator.Types (
    FailureReason (IndexNotReady),
    ReadyResponse,
    RefillRequest,
    RefillResponse (RefillFail),
    Request (..),
    SnapshotResponse,
    TransactRequest,
    TransactResponse (TransactFail),
 )
import Control.Concurrent (forkIO)
import Control.Exception (
    bracket,
    finally,
    try,
 )
import Data.Aeson (
    Value,
    decodeStrict',
    encode,
    object,
    (.=),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    Socket,
    SocketType (Stream),
    accept,
    bind,
    close,
    listen,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import System.Directory (removeFile)
import System.IO.Error (isDoesNotExistError)

{- | Per-handler entry points; the daemon wires these up
in 'Cardano.Node.Client.TxGenerator.Main'. v1 ships only
the readonly hooks; the mutating hooks are stubbed.
-}
data ServerHooks = ServerHooks
    { hooksReady :: IO ReadyResponse
    , hooksSnapshot :: IO SnapshotResponse
    , hooksTransact :: TransactRequest -> IO TransactResponse
    , hooksRefill :: RefillRequest -> IO RefillResponse
    }

{- | Build a 'ServerHooks' whose @transact@ and @refill@
arms are stubs returning @{"ok":false,"reason":
"index-not-ready"}@. Suitable for the v1 daemon until
T008 / T011 land. The two readonly hooks must still be
provided by the caller.
-}
stubHooks ::
    IO ReadyResponse ->
    IO SnapshotResponse ->
    ServerHooks
stubHooks ready snap =
    ServerHooks
        { hooksReady = ready
        , hooksSnapshot = snap
        , hooksTransact = \_ ->
            pure (TransactFail IndexNotReady)
        , hooksRefill = \_ ->
            pure (RefillFail IndexNotReady)
        }

{- | Run the NDJSON server on @socketPath@ until killed
(by exception). Removes any stale socket file at
@socketPath@ before binding.

Each accepted connection is handled in its own thread:
read one request line, write one response line, close.
Many concurrent @ready@ / @snapshot@ connections are
fine; @transact@ and @refill@ serialisation is the
caller's responsibility (FR-016).
-}
runServer :: FilePath -> ServerHooks -> IO ()
runServer socketPath hooks =
    bracket (openListenSocket socketPath) close $ \sock -> do
        listen sock 16
        let loop = do
                (conn, _) <- accept sock
                _ <- forkIO (handleConn hooks conn)
                loop
        loop

openListenSocket :: FilePath -> IO Socket
openListenSocket path = do
    removeIfPresent path
    sock <- socket AF_UNIX Stream 0
    bind sock (SockAddrUnix path)
    pure sock

removeIfPresent :: FilePath -> IO ()
removeIfPresent p = do
    r <- try (removeFile p)
    case r of
        Right () -> pure ()
        Left e
            | isDoesNotExistError e -> pure ()
            | otherwise -> ioError e

handleConn :: ServerHooks -> Socket -> IO ()
handleConn hooks conn = (`finally` close conn) $ do
    line <- recvLine conn
    case decodeStrict' line of
        Nothing ->
            sendLine conn (encode (errorResponse "malformed json"))
        Just req -> dispatch hooks conn req

dispatch :: ServerHooks -> Socket -> Request -> IO ()
dispatch hooks conn = \case
    ReqReady -> do
        rsp <- hooksReady hooks
        sendLine conn (encode rsp)
    ReqSnapshot -> do
        rsp <- hooksSnapshot hooks
        sendLine conn (encode rsp)
    ReqTransact body -> do
        rsp <- hooksTransact hooks body
        sendLine conn (encode rsp)
    ReqRefill body -> do
        rsp <- hooksRefill hooks body
        sendLine conn (encode rsp)

errorResponse :: Text -> Value
errorResponse msg = object ["error" .= msg]

{- | Read up to and including the first @\n@. The line
itself is returned without the trailing newline. Returns
the empty bytestring on EOF before any newline.
-}
recvLine :: Socket -> IO ByteString
recvLine s = go BS.empty
  where
    go acc = do
        chunk <- Net.recv s 4096
        if BS.null chunk
            then pure (stripNewline acc)
            else case BS.elemIndex 0x0A chunk of
                Just i ->
                    let (hd, _) = BS.splitAt i chunk
                     in pure (stripNewline (acc <> hd))
                Nothing -> go (acc <> chunk)

stripNewline :: ByteString -> ByteString
stripNewline bs
    | not (BS.null bs) && BS.last bs == 0x0A =
        BS.init bs
    | otherwise = bs

-- | Send one JSON line followed by @\n@.
sendLine :: Socket -> LBS.ByteString -> IO ()
sendLine s payload =
    Net.sendAll s $
        LBS.toStrict $
            toLazyByteString $
                Builder.lazyByteString payload
                    <> Builder.char7 '\n'
