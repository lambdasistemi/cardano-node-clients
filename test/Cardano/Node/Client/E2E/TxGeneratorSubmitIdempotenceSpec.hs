{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorSubmitIdempotenceSpec
Description : E2E for pre-submit chain-tip UTxO probe (spec 038)
License     : Apache-2.0

Verifies the pre-submit probe wired into the refill and
transact arms (specs/038-tx-gen-presubmit-probe). The probe
is a one-LSQ-round-trip 'GetUTxOByTxIn' check that runs
between tx construction and the submit primitive: if any
input is missing from the relay's current tip UTxO set,
the arm short-circuits with @IndexNotReady@ and skips
submit. See @lib/Cardano/Node/Client/TxGenerator/Daemon.hs@.

This spec verifies the no-regression contract (FR-005 /
FR-008 / SC-005): in steady-state operation the probe must
not change observable behaviour. The probe-catches-duplicate
case (SC-001 / SC-002) is exercised at scale by Antithesis;
deterministic injection of a 'ConnectionLost' that lands a
tx but cannot round-trip 'MsgAcceptTx' would require a
mock LTxS channel and is filed as the natural follow-up.

Test shape:

* Boot a fresh devnet relay.
* Boot daemon; wait ready.
* Drive a refill (creates fresh address, spends faucet
  input X1, derives change to a new faucet output).
* Drive 3 more refills; each picks a different fresh
  index and a different faucet input from the chain of
  change outputs.
* Drive 5 transacts spanning the resulting population.
* Snapshot @populationSize@; assert it grew strictly.

If the probe was buggy (e.g. always returning false) every
refill would short-circuit with @IndexNotReady@ and the
population would stay at zero. If the probe was wired
incorrectly (e.g. before tx construction), refills would
fail to compile or to type-check at the seam.
-}
module Cardano.Node.Client.E2E.TxGeneratorSubmitIdempotenceSpec (spec) where

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
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
    describe "tx-generator submit idempotence (spec 038)"
        $ it
            "4 refills + 5 transacts in steady state: probe \
            \is a no-op, population grows monotonically"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory
                    "txgen-submit-idem"
                    $ \dir -> do
                        let masterSeed = dir </> "master.seed"
                            faucetSkey = dir </> "faucet.skey"
                            stateDir = dir </> "state"
                            sock = dir </> "control.sock"
                        BS.writeFile
                            masterSeed
                            (BS.replicate 32 0x42)
                        BS.writeFile
                            faucetSkey
                            ( rawSerialiseSignKeyDSIGN
                                genesisSignKey
                            )
                        let cfg =
                                mkCfg
                                    nodeSocket
                                    sock
                                    stateDir
                                    masterSeed
                                    faucetSkey
                        pop <- runPhase cfg sock
                        pop `shouldSatisfy` (> 0)

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
            , dcReconnectPolicy = defaultReconnectPolicy
            , dcProbeConfig = defaultProbeConfig
            }

runPhase :: DaemonConfig -> FilePath -> IO Integer
runPhase cfg sockPath = do
    daemonT <- async (runDaemon cfg)
    result <-
        race
            (threadDelay 600_000_000)
            (drivePhase sockPath)
    cancel daemonT
    case result of
        Right pop -> pure pop
        Left _ -> error "phase timed out (10 min)"

drivePhase :: FilePath -> IO Integer
drivePhase path = do
    waitForConnect path
    pollReady path
    -- 4 refills. The probe runs on each — must not
    -- short-circuit in steady state.
    forM_ [1 .. 4 :: Int] $ \seed -> do
        let payload =
                BS8.pack
                    ( "{\"refill\":{\"seed\":"
                        <> show seed
                        <> "}}"
                    )
        rsp <- sendOne path payload
        assertOk
            ("refill seed=" <> show seed)
            rsp
    -- 5 transacts. Same: probe must be a no-op.
    forM_ [301 .. 305 :: Int] $ \seed -> do
        let payload = transactPayload seed
        rsp <- sendOne path payload
        assertOk
            ("transact seed=" <> show seed)
            rsp
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
        error
            ( "snapshot: not a JSON object: "
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
        error
            ( "tx-generator: control socket "
                <> path
                <> " never bound within 60s"
            )
    loop n = do
        attempt <-
            try @SomeException (connectAndClose path)
        case attempt of
            Right () -> pure ()
            Left _ ->
                threadDelay 500_000 >> loop (n + 1)

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
lookupValue k =
    KeyMap.lookup (Key.fromText (decodeKey k))
  where
    decodeKey =
        Key.toText . Key.fromString . BS8.unpack

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
