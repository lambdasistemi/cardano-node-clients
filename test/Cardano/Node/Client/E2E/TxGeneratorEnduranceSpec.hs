{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorEnduranceSpec
Description : Mixed-load endurance scenario (T017 / SC-007)
License     : Apache-2.0

Local equivalent of an Antithesis 3h composer-driven run.
Drives the daemon with a randomised mix of @transact@ and
@refill@ commands at variable cadence and asserts the
@populationSize@ curve is strictly monotonic (modulo
zero-delta ticks where the daemon answered
not-applicable).

Scaled-down for CI: 30 commands, ~30 s total. The
3-hour Antithesis run is the production scale.
-}
module Cardano.Node.Client.E2E.TxGeneratorEnduranceSpec (spec) where

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
import Control.Monad (foldM)
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
import System.Random (mkStdGen, randomR)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldSatisfy,
 )

-- | Number of commands fired during the scaled-down run.
endurancesteps :: Int
endurancesteps = 30

{- | Probability that a step is a @refill@ rather than a
@transact@.
-}
refillBias :: Double
refillBias = 0.1

spec :: Spec
spec =
    describe "tx-generator endurance (T017)"
        $ it
            ( "mixed transact/refill load over "
                <> show endurancesteps
                <> " steps; population strictly grows"
            )
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-endur" $ \dir -> do
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
                            (driveEndurance controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

driveEndurance :: FilePath -> IO ()
driveEndurance path = do
    waitForConnect path
    pollReady path
    -- Bootstrap with one refill so the first transact has
    -- a viable source.
    bootRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertOk "bootstrap refill" bootRsp
    -- Seeds for command selection.
    let coinFlipGen = mkStdGen 31_415
        cmdSeeds = [501 .. 500 + endurancesteps :: Int]
    -- Fold across commands, observing the population
    -- after each successful step.
    initialPop <- snapshotPopulation path
    let go (gen, pop) seedI = do
            let (b, gen') = randomR (0.0, 1.0 :: Double) gen
                isRefill = b < refillBias
                payload =
                    if isRefill
                        then
                            BS8.pack
                                ( "{\"refill\":{\"seed\":"
                                    <> show seedI
                                    <> "}}"
                                )
                        else
                            BS8.pack
                                ( "{\"transact\":{\"seed\":"
                                    <> show seedI
                                    <> ",\"fanout\":4,"
                                    <> "\"prob_fresh\":0.5}}"
                                )
            rsp <- sendOne path payload
            -- Tolerate not-applicable (no-pickable-source
            -- when the population is dust-only in the early
            -- iterations); strict failures still escape.
            allowOkOrNotApplicable
                ( "step "
                    <> show seedI
                    <> " (refill="
                    <> show isRefill
                    <> ")"
                )
                rsp
            pop' <- snapshotPopulation path
            -- Population is monotonic non-decreasing
            -- across every step.
            pop' `shouldSatisfy` (>= pop)
            pure (gen', pop')
    (_, finalPop) <- foldM go (coinFlipGen, initialPop) cmdSeeds
    finalPop `shouldSatisfy` (> initialPop)
    -- Demand at least 50 % of the predicted growth at
    -- the chosen prob_fresh — defends against a
    -- runaway not-applicable streak.
    let expected =
            initialPop
                + fromIntegral (endurancesteps `div` 2)
    finalPop `shouldSatisfy` (>= expected)

allowOkOrNotApplicable :: String -> ByteString -> IO ()
allowOkOrNotApplicable what rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        case lookupValue "ok" o of
            Just (Bool True) -> pure ()
            Just (Bool False) ->
                case lookupValue "reason" o of
                    Just (String r)
                        | r == "no-pickable-source"
                            || r == "faucet-not-known" ->
                            pure ()
                    other ->
                        error
                            ( what
                                <> ": ok=false with unexpected "
                                <> "reason: "
                                <> show other
                                <> " raw="
                                <> BS8.unpack rsp
                            )
            other ->
                error
                    ( what
                        <> ": malformed response: "
                        <> show other
                    )
    other ->
        error
            ( what
                <> ": not a JSON object: "
                <> show other
                <> " raw="
                <> BS8.unpack rsp
            )

snapshotPopulation :: FilePath -> IO Integer
snapshotPopulation path = do
    rsp <- sendOne path "{\"snapshot\":null}"
    case Aeson.decodeStrict rsp of
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
                    error
                        "snapshot: populationSize missing"
        other ->
            error
                ( "snapshot: not a JSON object: "
                    <> show other
                )

assertOk :: String -> ByteString -> IO ()
assertOk what rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        case lookupValue "ok" o of
            Just (Bool True) -> pure ()
            other ->
                error
                    ( what
                        <> ": expected ok=true, got: "
                        <> show other
                        <> " raw="
                        <> BS8.unpack rsp
                    )
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
