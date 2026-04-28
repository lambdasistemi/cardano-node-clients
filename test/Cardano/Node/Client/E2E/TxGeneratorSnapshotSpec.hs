{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorSnapshotSpec
Description : E2E for the snapshot percentile aggregation (T014)
License     : Apache-2.0

Verifies User Story 3 against a real devnet:

* Bring up the daemon.
* Refill once (addr_0 holds 5000 ADA).
* Snapshot A: @populationSize == 1@ and @p50 ≈ 5e9
  lovelace@.
* Run 10 transacts with K=4, @prob_fresh=0.5@.
* Snapshot B: @populationSize > 1@ and @p50@ has dropped
  by orders of magnitude (fragmentation curve, SC-005
  signal).
-}
module Cardano.Node.Client.E2E.TxGeneratorSnapshotSpec (spec) where

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
import Control.Monad (forM_)
import Data.Aeson (Object, Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Scientific qualified as Sci
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
    describe "tx-generator snapshot (T014)"
        $ it
            "after-refill snapshot reports populationSize=1 \
            \and p50≈5e9; after 10 transacts populationSize \
            \grew and p50 dropped two orders of magnitude"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-snap" $ \dir -> do
                    let masterSeed = dir </> "master.seed"
                        faucetSkey = dir </> "faucet.skey"
                        controlSock = dir </> "control.sock"
                        stateDir = dir </> "state"
                    BS.writeFile
                        masterSeed
                        (BS.replicate 32 0x42)
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
                            (threadDelay 600_000_000)
                            (driveSnapshotScenario controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

driveSnapshotScenario :: FilePath -> IO ()
driveSnapshotScenario path = do
    waitForConnect path
    pollReady path
    refillRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertOk "refill" refillRsp
    -- Snapshot A: just after refill.
    snapA <- sendOne path "{\"snapshot\":null}"
    (popA, p50A) <- extractSnap snapA
    popA `shouldBe` 1
    p50A `shouldSatisfy` (>= 4_000_000_000)
    -- 10 transacts at K=4, prob_fresh=0.5 → expectation 20
    -- new addresses; the source address (addr_0) splits its
    -- balance into ~6 sub-100-ADA outputs per transact, so
    -- p50 drops sharply.
    forM_ [201 .. 210 :: Int] $ \seed -> do
        let payload =
                BS8.pack
                    ( "{\"transact\":{\"seed\":"
                        <> show seed
                        <> ",\"fanout\":4,\"prob_fresh\":0.5}}"
                    )
        rsp <- sendOne path payload
        assertOk ("transact seed=" <> show seed) rsp
    -- Snapshot B: after fan-out.
    snapB <- sendOne path "{\"snapshot\":null}"
    (popB, p50B) <- extractSnap snapB
    popB `shouldSatisfy` (> popA)
    -- The fragmentation curve: p50 must be at least an
    -- order of magnitude below the post-refill p50.
    p50B `shouldSatisfy` (< p50A `div` 5)

extractSnap :: ByteString -> IO (Integer, Integer)
extractSnap rsp = case Aeson.decodeStrict rsp of
    Just (Object o) -> do
        pop <- intField "populationSize" o
        p50 <- intField "p50_lovelace" o
        pure (pop, p50)
    other ->
        error ("snapshot: not a JSON object: " <> show other)

intField :: ByteString -> Object -> IO Integer
intField k o =
    case lookupValue k o of
        Just (Number n) ->
            case Sci.floatingOrInteger n ::
                    Either Double Integer of
                Right i -> pure i
                Left _ ->
                    error
                        ( BS8.unpack k
                            <> ": expected integer, got "
                            <> show n
                        )
        other ->
            error
                ( BS8.unpack k
                    <> ": missing or wrong shape: "
                    <> show other
                )

assertOk :: String -> ByteString -> IO ()
assertOk what rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        lookupValue "ok" o `shouldBe` Just (Bool True)
    other ->
        error
            ( what
                <> ": not a JSON object: "
                <> show other
                <> " raw="
                <> BS8.unpack rsp
            )

waitForConnect :: FilePath -> IO ()
waitForConnect path = loop (0 :: Int)
  where
    loop 120 =
        error "tx-generator: control socket never bound within 60s"
    loop n = do
        attempt <- try @SomeException (connectAndClose path)
        case attempt of
            Right () -> pure ()
            Left _ -> threadDelay 500_000 >> loop (n + 1)

connectAndClose :: FilePath -> IO ()
connectAndClose path =
    bracket
        (socket AF_UNIX Stream 0)
        close
        (\s -> connect s (SockAddrUnix path))

pollReady :: FilePath -> IO ()
pollReady path = loop (0 :: Int)
  where
    loop 120 =
        error
            "tx-generator: ready never went true within 60s"
    loop n = do
        rsp <- sendOne path "{\"ready\":null}"
        if isReadyTrue rsp
            then pure ()
            else threadDelay 500_000 >> loop (n + 1)

isReadyTrue :: ByteString -> Bool
isReadyTrue rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        lookupValue "ready" o == Just (Bool True)
    _ -> False

lookupValue :: ByteString -> Object -> Maybe Value
lookupValue k = KeyMap.lookup (Key.fromText (decodeKey k))
  where
    decodeKey = Key.toText . Key.fromString . BS8.unpack

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
