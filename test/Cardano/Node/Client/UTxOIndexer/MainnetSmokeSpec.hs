{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.MainnetSmokeSpec
Description : Opt-in mainnet cold-boot smoke for the UTxO indexer
License     : Apache-2.0

Cold-boot smoke against a real mainnet node socket. The test is
gated by @UTXO_INDEXER_MAINNET_SMOKE@ so CI remains self-contained.
-}
module Cardano.Node.Client.UTxOIndexer.MainnetSmokeSpec (spec) where

import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Trace (N2CEvent (..))
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    InterestSet (..),
    Readiness (..),
    withChainSyncFollower,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    BlockHash (..),
    SlotNo (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
import Control.Concurrent.STM (
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
 )
import Control.Tracer (Tracer (..), nullTracer)
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as Text
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    getOneEraHash,
 )
import Ouroboros.Consensus.Ledger.Query (Query (GetChainPoint))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    pendingWith,
 )

spec :: Spec
spec =
    describe "mainnet smoke" $
        it "cold boots past Byron without ApplyConflict" $ do
            lookupEnv "UTXO_INDEXER_MAINNET_SMOKE" >>= \case
                Nothing ->
                    pendingWith
                        "set UTXO_INDEXER_MAINNET_SMOKE to a mainnet node socket"
                Just socketPath ->
                    runMainnetSmoke socketPath

runMainnetSmoke :: FilePath -> IO ()
runMainnetSmoke socketPath = do
    startPoint <- resolveMainnetTipPoint socketPath
    withSystemTempDirectory "utxo-indexer-mainnet-smoke" $ \tmp ->
        withRocksDBIndexer (tmp </> "db") $ \idx -> do
            eventsVar <- newTVarIO ([] :: [N2CEvent])
            let tracer =
                    Tracer $ \ev ->
                        atomically (modifyTVar' eventsVar (ev :))
                cfg =
                    ChainSyncConfig
                        { csRelaySocket = socketPath
                        , csNetworkMagic = mainnetMagic
                        , csByronEpochSlots = 21_600
                        , csStartPoint = Just startPoint
                        , csReadyThresholdSlots = 60
                        , csSecurityParamK = 2_160
                        , csReconnectPolicy = defaultReconnectPolicy
                        , csProbeConfig = defaultProbeConfig
                        , csInterestSet = IndexAll
                        , csBlockTracer = nullTracer
                        , csTipTracer = nullTracer
                        }
            withChainSyncFollower tracer cfg idx $ \fh ->
                waitForMainnetProgress
                    fh
                    eventsVar
                    (SlotNo 5_000_000)
                    60_000_000

resolveMainnetTipPoint :: FilePath -> IO (SlotNo, BlockHash)
resolveMainnetTipPoint socketPath = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    withAsync (runNodeClient mainnetMagic socketPath lsq ltxs) $ \_ -> do
        mPoint <- timeout 10_000_000 (queryLSQ lsq GetChainPoint)
        case mPoint of
            Nothing ->
                failResolve
                    "mainnet smoke could not query the node tip within 10s"
            Just (Network.Point Network.Point.Origin) ->
                failResolve
                    "mainnet smoke node tip is Origin"
            Just
                ( Network.Point
                        ( Network.Point.At
                                (Network.Point.Block slot hash)
                            )
                    ) ->
                    pure
                        ( SlotNo (Network.unSlotNo slot)
                        , BlockHash
                            (SBS.fromShort (getOneEraHash hash))
                        )
  where
    failResolve msg =
        expectationFailure msg >> pure (SlotNo 0, BlockHash mempty)

waitForMainnetProgress ::
    FollowerHandle ->
    TVar [N2CEvent] ->
    SlotNo ->
    Int ->
    IO ()
waitForMainnetProgress fh eventsVar targetSlot =
    go
  where
    stepMicros = 250_000

    go remaining
        | remaining <= 0 = do
            events <- reverse <$> readTVarIO eventsVar
            expectationFailure $
                "mainnet smoke did not advance past "
                    <> show targetSlot
                    <> " within 60s; recent events: "
                    <> show (take 8 (reverse events))
        | otherwise = do
            failOnApplyConflict eventsVar
            poll (fhAsync fh) >>= \case
                Just (Left e) ->
                    expectationFailure $
                        "mainnet smoke follower crashed: " <> show e
                Just (Right ()) ->
                    expectationFailure
                        "mainnet smoke follower exited cleanly"
                Nothing -> pure ()
            readiness <- atomically (fhReadiness fh)
            case rProcessedSlot readiness of
                Just slot | slot > targetSlot -> pure ()
                _ -> do
                    threadDelay stepMicros
                    go (remaining - stepMicros)

failOnApplyConflict :: TVar [N2CEvent] -> IO ()
failOnApplyConflict eventsVar = do
    events <- readTVarIO eventsVar
    case [reason | IndexerDisconnected reason <- events, isApplyConflict reason] of
        reason : _ ->
            expectationFailure $
                "mainnet smoke observed ApplyConflict: "
                    <> Text.unpack reason
        [] -> pure ()

isApplyConflict :: Text.Text -> Bool
isApplyConflict = Text.isInfixOf "ApplyConflict"

mainnetMagic :: NetworkMagic
mainnetMagic = NetworkMagic 764_824_073
