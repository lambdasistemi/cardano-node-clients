{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.Adversary.Daemon
Description : cardano-adversary daemon — wires Server, signals, sockets
License     : Apache-2.0

Composes the cardano-adversary daemon's responsibilities:

* the NDJSON control wire from
  'Cardano.Node.Client.Adversary.Server',
* signal handling so the container stops cleanly on @SIGTERM@,
* the @ready@ hook,
* the real @chain_sync_flap@ hook that drives
  'repeatedAdversaryApplication'.

The chain-points file is read on every @chain_sync_flap@ request
so the daemon picks up new points written by @tracer-sidecar@
without restarting.
-}
module Cardano.Node.Client.Adversary.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Node.Client.Adversary.Application (
    Limit (..),
    repeatedAdversaryApplication,
 )
import Cardano.Node.Client.Adversary.ChainPoints (
    generatePoints,
    parseChainPointSamples,
 )
import Cardano.Node.Client.Adversary.RandomSource (splitFromSeed)
import Cardano.Node.Client.Adversary.Server (
    ServerHooks (..),
    runServer,
 )
import Cardano.Node.Client.Adversary.Types (
    ChainSyncFlapArgs (..),
    ChainSyncFlapDetails (..),
    ChainSyncFlapFailure (..),
    ReadyDetails (..),
    Response (..),
 )
import Control.Concurrent (
    MVar,
    newEmptyMVar,
    putMVar,
    takeMVar,
 )
import Control.Concurrent.Async (race_)
import Control.Exception (IOException, catch, try)
import Control.Tracer (Tracer (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket (HostName, PortNumber)
import Ouroboros.Network.Magic (NetworkMagic)
import System.Directory (doesFileExist, removeFile)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Signals (
    Handler (Catch),
    installHandler,
    sigTERM,
 )

-- | Top-level daemon configuration.
data DaemonConfig = DaemonConfig
    { daemonControlSocket :: FilePath
    -- ^ Path of the Unix control socket. The daemon binds here
    -- and unlinks on shutdown.
    , daemonProducerHosts :: [HostName]
    -- ^ Producer hostnames the @chain_sync_flap@ endpoint targets.
    , daemonProducerPort :: PortNumber
    -- ^ N2N port for @chain_sync_flap@.
    , daemonNetworkMagic :: NetworkMagic
    -- ^ Network magic used in the N2N handshake.
    , daemonChainPointsFile :: Maybe FilePath
    -- ^ Path of the chain-points file produced by
    -- @tracer-sidecar@. When 'Nothing', the @chain_sync_flap@
    -- endpoint always returns 'CsffNoChainPointsFile'.
    }

{- | Run the daemon: install signal handler, start NDJSON server,
block until SIGTERM. On SIGTERM unlink the socket and exit.
-}
runDaemon :: DaemonConfig -> IO ()
runDaemon cfg = do
    hPutStrLn stderr $
        "cardano-adversary: starting on "
            <> daemonControlSocket cfg
    shutdown <- newEmptyMVar :: IO (MVar ())
    _ <- installHandler sigTERM (Catch (putMVar shutdown ())) Nothing
    let serverThread = runServer (daemonControlSocket cfg) (mkHooks cfg)
        signalThread = takeMVar shutdown
    race_ serverThread signalThread
    cleanup cfg

mkHooks :: DaemonConfig -> ServerHooks
mkHooks cfg =
    ServerHooks
        { hooksReady = pure (readyDetails cfg)
        , hooksChainSyncFlap = handleChainSyncFlap cfg
        }

readyDetails :: DaemonConfig -> ReadyDetails
readyDetails cfg =
    ReadyDetails
        { readyOverall = True
        , readyN2NHandshakeOk = False
        , readyConfiguredHosts =
            map (T.pack :: HostName -> Text) (daemonProducerHosts cfg)
        }

handleChainSyncFlap :: DaemonConfig -> ChainSyncFlapArgs -> IO Response
handleChainSyncFlap cfg args
    | null (daemonProducerHosts cfg) =
        pure (RespChainSyncFlapFail CsffNoProducers)
    | otherwise = case daemonChainPointsFile cfg of
        Nothing -> pure (RespChainSyncFlapFail CsffNoChainPointsFile)
        Just path -> do
            present <- doesFileExist path
            if not present
                then pure (RespChainSyncFlapFail CsffNoChainPointsFile)
                else runFlap cfg path args

runFlap :: DaemonConfig -> FilePath -> ChainSyncFlapArgs -> IO Response
runFlap cfg path args = do
    contentE <- try @IOException (readFile path)
    case contentE of
        Left _ -> pure (RespChainSyncFlapFail CsffNoChainPointsFile)
        Right content -> case parseChainPointSamples content of
            Nothing -> pure (RespChainSyncFlapFail CsffNoChainPointsYet)
            Just samples -> do
                let gen = splitFromSeed (csfSeed args)
                    points = generatePoints gen samples
                    nConns = max 1 (fromIntegral (csfNConns args) :: Int)
                    capped = NE.fromList (NE.take nConns points)
                    limit = Limit (csfLimit args)
                    tracer = Tracer (hPutStrLn stderr)
                repeatedAdversaryApplication
                    tracer
                    nConns
                    (daemonNetworkMagic cfg)
                    (daemonProducerHosts cfg)
                    (daemonProducerPort cfg)
                    capped
                    limit
                pure $
                    RespChainSyncFlapOk
                        ChainSyncFlapDetails
                            { csfdConnections = nConns
                            , csfdPeerNames =
                                map T.pack (daemonProducerHosts cfg)
                            , csfdLimit = csfLimit args
                            }

cleanup :: DaemonConfig -> IO ()
cleanup cfg = do
    hPutStrLn stderr "cardano-adversary: SIGTERM received, shutting down"
    removeFile (daemonControlSocket cfg)
        `catch` \e ->
            if isDoesNotExistError e
                then pure ()
                else ioError e
