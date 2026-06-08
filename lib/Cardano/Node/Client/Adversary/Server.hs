{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.Adversary.Server
Description : NDJSON Unix-socket control wire for cardano-adversary
License     : Apache-2.0

Listens on a Unix domain socket and serves the cardano-adversary
daemon's control wire as newline-delimited JSON. One request per
connection, single response, then EOF + close. Same idiom as
'Cardano.Node.Client.TxGenerator.Server' and
'Cardano.Node.Client.UTxOIndexer.Server'.

Endpoints route through 'ServerHooks', wired up by the daemon. PR
B ships only the @ready@ hook with real semantics; @chain_sync_flap@
is reserved with a 'RespNotImplemented' stub. The hook signature is
already shaped for the real handler so PR C only swaps the body.

Wire schemas live in
@specs/036-cardano-adversary/contracts/control-wire.md@.
-}
module Cardano.Node.Client.Adversary.Server (
    -- * Server
    runServer,

    -- * Hook record
    ServerHooks (..),
    stubHooks,
) where

import Cardano.Node.Client.Adversary.Types (
    ChainSyncFlapArgs,
    ErrorReason (..),
    ReadyDetails,
    Request (..),
    Response (..),
 )
import Control.Concurrent (forkIO)
import Control.Exception (
    bracket,
    finally,
    try,
 )
import Data.Aeson (
    decodeStrict',
    encode,
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
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

{- | Per-endpoint entry points; the daemon wires these up.

PR B ships a real 'hooksReady' and a stub 'hooksChainSyncFlap'.
PR C swaps the stub for the real chain-sync misbehaviour body.
-}
data ServerHooks = ServerHooks
    { hooksReady :: IO ReadyDetails
    , hooksChainSyncFlap :: ChainSyncFlapArgs -> IO Response
    }

{- | Build a 'ServerHooks' whose 'hooksChainSyncFlap' arm returns
'RespNotImplemented'. The 'ready' hook must still be supplied by
the caller.
-}
stubHooks :: IO ReadyDetails -> ServerHooks
stubHooks ready =
    ServerHooks
        { hooksReady = ready
        , hooksChainSyncFlap = \_ -> pure RespNotImplemented
        }

{- | Run the NDJSON server on @socketPath@ until killed (by
exception). Removes any stale socket file at @socketPath@ before
binding.

Each accepted connection is handled in its own thread: read one
request line, write one response line, close. Many concurrent
@ready@ connections are fine; misbehaviour endpoints are
free to serialise themselves at the hook layer when their
underlying state demands it.
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
            sendLine conn (encode (RespError ErrMalformedJson))
        Just req -> dispatch hooks conn req

dispatch :: ServerHooks -> Socket -> Request -> IO ()
dispatch hooks conn = \case
    ReqReady -> do
        rsp <- hooksReady hooks
        sendLine conn (encode (RespReady rsp))
    ReqChainSyncFlap body -> do
        rsp <- hooksChainSyncFlap hooks body
        sendLine conn (encode rsp)

{- | Read up to and including the first @\n@. The line itself is
returned without the trailing newline. Returns the empty
bytestring on EOF before any newline.
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
