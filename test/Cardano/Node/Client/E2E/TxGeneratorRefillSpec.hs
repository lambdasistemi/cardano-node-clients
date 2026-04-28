{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorRefillSpec
Description : E2E for the tx-generator refill arm (T008)
License     : Apache-2.0

Verifies User Story 2 against a real devnet:

* Send @{"refill":{"seed":1}}@ against a freshly-booted
  daemon whose population is empty and whose faucet (the
  genesis UTxO holder) has value.
* Expect @ok=true@, @fresh_index=0@, a non-zero
  @value_lovelace@, @awaited=true@.
* Expect a follow-up @{"snapshot":null}@ to report
  @populationSize=1@.

Acceptance Scenario 2 (faucet-not-known) is not exercised
here because the devnet harness always brings up a faucet
with funds; it would require a separate fixture and is
covered by the @T007@ ready probe contract.
-}
module Cardano.Node.Client.E2E.TxGeneratorRefillSpec (spec) where

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
import Data.ByteString.Char8 qualified as BS8
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
    describe "tx-generator refill arm (T008)"
        $ it
            "refill from faucet to a fresh address: \
            \fresh_index=0, value_lovelace>0, awaited=true; \
            \follow-up snapshot reports populationSize=1"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-refill" $ \dir -> do
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
                            (threadDelay 90_000_000)
                            (driveRefillScenario controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

driveRefillScenario :: FilePath -> IO ()
driveRefillScenario path = do
    waitForConnect path
    pollReady path
    refillRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertRefillOk refillRsp
    snapshotRsp <- sendOne path "{\"snapshot\":null}"
    assertPopulationSizeOne snapshotRsp

assertRefillOk :: ByteString -> IO ()
assertRefillOk rsp = case Aeson.decodeStrict rsp of
    Just (Object o) -> do
        lookupValue "ok" o `shouldBe` Just (Bool True)
        lookupValue "fresh_index" o `shouldBe` Just (Number 0)
        case lookupValue "value_lovelace" o of
            Just (Number n) ->
                n `shouldSatisfy` (> 0)
            _ ->
                error "refill: value_lovelace missing or not a number"
        lookupValue "awaited" o `shouldBe` Just (Bool True)
    other ->
        error
            ( "refill response is not a JSON object: "
                <> show other
                <> " raw="
                <> BS8.unpack rsp
            )

assertPopulationSizeOne :: ByteString -> IO ()
assertPopulationSizeOne rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        lookupValue "populationSize" o `shouldBe` Just (Number 1)
    other ->
        error
            ( "snapshot response is not a JSON object: "
                <> show other
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
lookupValue k = KeyMap.lookup (Key.fromText (decodeUtf8' k))
  where
    decodeUtf8' = Key.toText . Key.fromString . BS8.unpack

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
