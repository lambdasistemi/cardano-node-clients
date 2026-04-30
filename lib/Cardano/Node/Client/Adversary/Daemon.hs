{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.Adversary.Daemon
Description : cardano-adversary daemon — wires Server, signals, sockets
License     : Apache-2.0

Composes the cardano-adversary daemon's three responsibilities for
PR B:

* the NDJSON control wire from
  'Cardano.Node.Client.Adversary.Server',
* signal handling so the container stops cleanly on @SIGTERM@,
* the @ready@ hook (always reports ready in PR B because no N2N
  warmup happens yet).

PR C adds the @chain_sync_flap@ misbehaviour body and replaces the
'stubHooks' wiring with one that holds an N2N pool.
-}
module Cardano.Node.Client.Adversary.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Node.Client.Adversary.Server (
    ServerHooks,
    runServer,
    stubHooks,
 )
import Cardano.Node.Client.Adversary.Types (
    ReadyDetails (..),
 )
import Control.Concurrent (
    MVar,
    newEmptyMVar,
    putMVar,
    takeMVar,
 )
import Control.Concurrent.Async (race_)
import Control.Exception (catch)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket (HostName, PortNumber)
import Ouroboros.Network.Magic (NetworkMagic)
import System.Directory (removeFile)
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
    -- ^ Producer hostnames the daemon will eventually target.
    -- PR B only echoes them back via 'ReadyDetails'.
    , daemonProducerPort :: PortNumber
    -- ^ N2N port. Echoed by 'ReadyDetails' for diagnostic value.
    , daemonNetworkMagic :: NetworkMagic
    -- ^ Network magic. Echoed by 'ReadyDetails' for diagnostic
    -- value; required by every future N2N misbehaviour endpoint.
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
mkHooks cfg = stubHooks (pure (readyDetails cfg))

readyDetails :: DaemonConfig -> ReadyDetails
readyDetails cfg =
    ReadyDetails
        { readyOverall = True
        , readyN2NHandshakeOk = False
        , readyConfiguredHosts =
            map (T.pack :: HostName -> Text) (daemonProducerHosts cfg)
        }

cleanup :: DaemonConfig -> IO ()
cleanup cfg = do
    hPutStrLn stderr "cardano-adversary: SIGTERM received, shutting down"
    removeFile (daemonControlSocket cfg)
        `catch` \e ->
            if isDoesNotExistError e
                then pure ()
                else ioError e
