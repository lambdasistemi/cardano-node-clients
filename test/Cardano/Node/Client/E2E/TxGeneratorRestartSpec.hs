{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorRestartSpec
Description : E2E for daemon restart resilience (T016 / SC-006)
License     : Apache-2.0

Verifies that the daemon's persisted state (master seed
+ @next-hd-index@) survives a process restart against the
same state-dir + same devnet:

* Bring up daemon A; wait ready; refill + run 5
  transacts; snapshot @populationSize_A@.
* Cancel daemon A; bring up daemon B with the same
  @--state-dir@, master seed, and faucet key but a fresh
  @--control-socket@ (the old socket file is deleted by
  the new bind path); wait ready.
* Snapshot @populationSize_B@; assert
  @populationSize_B == populationSize_A@ — i.e. the
  in-memory indexer rebuilt from chain-sync from
  @Origin@ but the on-disk @next-hd-index@ was
  preserved.
* Run 5 more transacts; snapshot
  @populationSize_C@; assert it strictly grew.

This is a partial SC-006 verification: full byte-for-byte
txId determinism across restarts requires a deeper
fixture and is a bounded follow-up.
-}
module Cardano.Node.Client.E2E.TxGeneratorRestartSpec (spec) where

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
    describe "tx-generator restart resilience (T016)"
        $ it
            "refill + 5 transacts + restart + 5 more transacts: \
            \populationSize survives the restart and keeps growing"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-restart" $ \dir -> do
                    let masterSeed = dir </> "master.seed"
                        faucetSkey = dir </> "faucet.skey"
                        stateDir = dir </> "state"
                        sockA = dir </> "control-A.sock"
                        sockB = dir </> "control-B.sock"
                    BS.writeFile
                        masterSeed
                        (BS.replicate 32 0x42)
                    BS.writeFile
                        faucetSkey
                        ( rawSerialiseSignKeyDSIGN genesisSignKey
                        )
                    let cfgA = mkCfg nodeSocket sockA stateDir masterSeed faucetSkey
                        cfgB = mkCfg nodeSocket sockB stateDir masterSeed faucetSkey
                    -- Phase A: refill + 5 transacts.
                    popA <- runPhaseA cfgA sockA
                    -- Phase B: restart, observe the
                    -- preserved nextHDIndex, run 5 more.
                    popB <- runPhaseB cfgB sockB popA
                    popB `shouldSatisfy` (> popA)

mkCfg ::
    FilePath ->
    FilePath ->
    FilePath ->
    FilePath ->
    FilePath ->
    DaemonConfig
mkCfg nodeSocket controlSock stateDir masterSeed faucetSkey =
    let NetworkMagic m = devnetMagic
     in DaemonConfig
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

runPhaseA :: DaemonConfig -> FilePath -> IO Integer
runPhaseA cfg sockPath = do
    daemonT <- async (runDaemon cfg)
    result <-
        race
            (threadDelay 600_000_000)
            (drivePhaseA sockPath)
    cancel daemonT
    -- give the cancelled async a moment to release
    -- the socket file before phase B binds a new one.
    threadDelay 1_000_000
    case result of
        Right pop -> pure pop
        Left _ -> error "phase A timed out (10 min)"

drivePhaseA :: FilePath -> IO Integer
drivePhaseA path = do
    waitForConnect path
    pollReady path
    refillRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertOk "refill" refillRsp
    forM_ [301 .. 305 :: Int] $ \seed -> do
        let payload = transactPayload seed
        rsp <- sendOne path payload
        assertOk ("transact A seed=" <> show seed) rsp
    snapRsp <- sendOne path "{\"snapshot\":null}"
    extractPopulation snapRsp

runPhaseB ::
    DaemonConfig ->
    FilePath ->
    Integer ->
    IO Integer
runPhaseB cfg sockPath popA = do
    daemonT <- async (runDaemon cfg)
    result <-
        race
            (threadDelay 600_000_000)
            (drivePhaseB sockPath popA)
    cancel daemonT
    case result of
        Right pop -> pure pop
        Left _ -> error "phase B timed out (10 min)"

drivePhaseB :: FilePath -> Integer -> IO Integer
drivePhaseB path popA = do
    waitForConnect path
    pollReady path
    -- First snapshot AFTER restart but BEFORE any new
    -- transacts: population must equal phase A's final
    -- value (state survived restart).
    snap0 <- sendOne path "{\"snapshot\":null}"
    pop0 <- extractPopulation snap0
    pop0 `shouldBe` popA
    -- 5 more transacts, distinct seeds from phase A so
    -- the txIds don't collide on chain.
    forM_ [401 .. 405 :: Int] $ \seed -> do
        let payload = transactPayload seed
        rsp <- sendOne path payload
        assertOk ("transact B seed=" <> show seed) rsp
    snapRsp <- sendOne path "{\"snapshot\":null}"
    extractPopulation snapRsp

transactPayload :: Int -> ByteString
transactPayload seed =
    BS8.pack
        ( "{\"transact\":{\"seed\":"
            <> show seed
            <> ",\"fanout\":4,\"prob_fresh\":0.5}}"
        )

extractPopulation :: ByteString -> IO Integer
extractPopulation rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        case lookupValue "populationSize" o of
            Just (Number n) ->
                case Sci.floatingOrInteger n ::
                        Either Double Integer of
                    Right i -> pure i
                    Left _ ->
                        error
                            ( "populationSize not integer: "
                                <> show n
                            )
            _ ->
                error "snapshot: populationSize missing"
    other ->
        error ("snapshot: not a JSON object: " <> show other)

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
        error
            ( "tx-generator: control socket "
                <> path
                <> " never bound within 60s"
            )
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
