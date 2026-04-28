{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorTransactSpec
Description : E2E for the tx-generator transact arm (T012)
License     : Apache-2.0

Verifies User Story 1 against a real devnet:

* Refill once to seed @addr_0@ with 5000 ADA.
* Send 20 sequential @{"transact":{"seed":N,...}}@
  requests with K=4 and @prob_fresh=0.5@; assert each
  response is @ok=true@.
* Final @{"snapshot":null}@ reports a populationSize that
  grew by at least @0.4 * 20 * 4 = 32@ (we allow some
  variance below the SC-001 mean of @20·4·0.5 = 40@).

SC-002 (replay determinism) and SC-004 (not-applicable
within 1 s) are bounded follow-ups: replay determinism
needs a fresh-devnet restart cycle and SC-004 needs a
contrived dust-only fixture; both warrant their own
spec rather than further bloat this one.
-}
module Cardano.Node.Client.E2E.TxGeneratorTransactSpec (spec) where

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
    describe "tx-generator transact arm (T012)"
        $ it
            "refill + 20 transacts (K=4, prob_fresh=0.5): \
            \each ok=true; population grows by ≥ 32"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-tx" $ \dir -> do
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
                            (driveTransactScenario controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

driveTransactScenario :: FilePath -> IO ()
driveTransactScenario path = do
    waitForConnect path
    pollReady path
    -- Refill once to fund addr_0 with 5000 ADA.
    refillRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertOk "refill" refillRsp
    -- 20 transacts with K=4, prob_fresh=0.5.
    forM_ [101 .. 120 :: Int] $ \seed -> do
        let payload =
                BS8.pack
                    ( "{\"transact\":{\"seed\":"
                        <> show seed
                        <> ",\"fanout\":4,\"prob_fresh\":0.5}}"
                    )
        rsp <- sendOne path payload
        assertOk ("transact seed=" <> show seed) rsp
    -- Final snapshot: SC-001 lower bound is 0.5 * 20 * 4 = 40
    -- on average; allow 32 (= 40 - 8) to absorb seed-specific
    -- variance.
    snapRsp <- sendOne path "{\"snapshot\":null}"
    assertPopulationGrew snapRsp 33

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

assertPopulationGrew :: ByteString -> Integer -> IO ()
assertPopulationGrew rsp lowerBound = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        case lookupValue "populationSize" o of
            Just (Number n) ->
                case Sci.floatingOrInteger n :: Either Double Integer of
                    Right k ->
                        k `shouldSatisfy` (>= lowerBound)
                    Left _ ->
                        error
                            ( "populationSize not integer: "
                                <> show n
                            )
            _ ->
                error "snapshot: populationSize missing"
    other ->
        error ("snapshot: not a JSON object: " <> show other)

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
