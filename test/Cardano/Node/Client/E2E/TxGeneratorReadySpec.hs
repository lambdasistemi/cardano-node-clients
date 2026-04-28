{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorReadySpec
Description : E2E smoke for the tx-generator daemon (T007)
License     : Apache-2.0

Verifies that the cardano-tx-generator daemon brings up
end-to-end against a real devnet:

* opens one N2C connection (chain-sync feeds the embedded
  in-memory indexer; LSQ + LTxS are open and idle);
* mounts the NDJSON control wire on a Unix socket and
  responds to @{"ready":null}@;
* the readiness probe transitions @ready=false@ →
  @ready=true@ within a bounded window (cold-start indexer
  catching up from a one-block-old devnet);
* @{"snapshot":null}@ returns a JSON object with
  @populationSize@ = 0 (no transacts yet).

Does NOT exercise transact / refill / snapshot percentile
aggregation — those land in T008 / T011 / T013.
-}
module Cardano.Node.Client.E2E.TxGeneratorReadySpec (spec) where

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    async,
    cancel,
    race,
 )
import Control.Exception (
    SomeException,
    bracket,
    try,
 )
import Data.Aeson (Object, Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    SocketType (Stream),
    close,
    connect,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "tx-generator daemon (T007)"
        $ it
            "binds the control socket; ready transitions to true; \
            \snapshot reports populationSize=0 on cold start"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-e2e" $ \dir -> do
                    let masterSeed = dir </> "master.seed"
                        faucetSkey = dir </> "faucet.skey"
                        controlSock = dir </> "control.sock"
                        stateDir = dir </> "state"
                    -- Pinned 32-byte master seed.
                    BS.writeFile
                        masterSeed
                        (BS.replicate 32 0x42)
                    -- Faucet skey: bytes are loaded but not
                    -- used in T007; provide the genesis
                    -- skey to lock the CLI shape.
                    BS.writeFile
                        faucetSkey
                        ( rawSerialiseSignKeyDSIGN genesisSignKey
                        )
                    let NetworkMagic m = devnetMagic
                        cfg =
                            DaemonConfig
                                { dcRelaySocket = nodeSocket
                                , dcControlSocket = controlSock
                                , dcStateDir = stateDir
                                , dcMasterSeedFile = masterSeed
                                , dcFaucetSKeyFile = faucetSkey
                                , dcNetworkMagic = m
                                , dcByronEpochSlots = 432_000
                                , dcAwaitTimeoutSeconds = 30
                                , dcReadyThresholdSlots = 10
                                , dcSecurityParamK = 2160
                                , dcDbPath = Nothing
                                }
                    daemonThread <- async (runDaemon cfg)
                    result <-
                        race
                            (threadDelay 60_000_000)
                            (runProbes controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

{- | Wait for the control socket to bind, then poll
@ready@ until it returns @ready=true@, then issue one
@snapshot@ and assert its shape.
-}
runProbes :: FilePath -> IO ()
runProbes path = do
    waitForConnect path
    pollReady path
    snapshotShouldBeColdStart path

waitForConnect :: FilePath -> IO ()
waitForConnect path = loop 0
  where
    loop :: Int -> IO ()
    loop 120 =
        error "tx-generator: control socket never bound within 60s"
    loop n = do
        attempt <- try @SomeException (connectAndClose path)
        case attempt of
            Right () -> pure ()
            Left _ -> do
                threadDelay 500_000
                loop (n + 1)

connectAndClose :: FilePath -> IO ()
connectAndClose path =
    bracket
        (socket AF_UNIX Stream 0)
        close
        (\s -> connect s (SockAddrUnix path))

pollReady :: FilePath -> IO ()
pollReady path = loop 0
  where
    loop :: Int -> IO ()
    loop 60 =
        error
            "tx-generator: ready never went true within 30s"
    loop n = do
        rsp <- sendOne path "{\"ready\":null}"
        if isReadyTrue rsp
            then pure ()
            else do
                threadDelay 500_000
                loop (n + 1)

snapshotShouldBeColdStart :: FilePath -> IO ()
snapshotShouldBeColdStart path = do
    rsp <- sendOne path "{\"snapshot\":null}"
    case Aeson.decodeStrict rsp of
        Just (Object o) ->
            lookupValue "populationSize" o `shouldBe` Just (Number 0)
        other ->
            error ("snapshot: not a JSON object: " <> show other)

isReadyTrue :: ByteString -> Bool
isReadyTrue rsp =
    case Aeson.decodeStrict rsp of
        Just (Object o) ->
            lookupValue "ready" o == Just (Bool True)
        _ -> False

lookupValue :: ByteString -> Object -> Maybe Value
lookupValue k = KeyMap.lookup (Key.fromText (decodeUtf8 k))
  where
    decodeUtf8 = Key.toText . Key.fromString . map (toEnum . fromIntegral) . BS.unpack

sendOne :: FilePath -> ByteString -> IO ByteString
sendOne path req =
    bracket
        (socket AF_UNIX Stream 0)
        close
        ( \s -> do
            connect s (SockAddrUnix path)
            Net.sendAll s (req <> "\n")
            recvAll s BS.empty
        )
  where
    recvAll s acc = do
        chunk <- Net.recv s 4096
        if BS.null chunk
            then pure acc
            else recvAll s (acc <> chunk)

isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _ = False
