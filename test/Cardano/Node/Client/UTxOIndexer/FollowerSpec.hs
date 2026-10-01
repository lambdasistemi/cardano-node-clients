{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.FollowerSpec
Description : Unit tests for the chain-sync follower primitive
License     : Apache-2.0

Exercises 'withChainSyncFollower' against a caller-owned
'IndexerHandle' returned by 'withInMemoryIndexer'. The
follower's reconnect supervisor probes a missing relay
socket and retries forever; the inner action runs to
completion before the bracket cancels the follower thread.

This unit suite proves the API surface — the caller can
write to the same handle the follower will (eventually)
write to, and the readiness 'TVar' is reachable via the
exposed 'STM' action. The "follower actually reaches
readiness after a live chain-sync session" claim is
exercised by the existing
"Cardano.Node.Client.E2E.UTxOIndexerReconnectSpec" E2E
against a devnet node.
-}
module Cardano.Node.Client.UTxOIndexer.FollowerSpec (spec) where

import Cardano.Node.Client.N2C.ChainSync (HeaderPoint)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.TxHistoryIndexer.Indexer (
    HistoryIndexer,
    withInMemoryHistoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    InterestSet (..),
    Readiness (..),
    applyBlockOps,
    coldBootResumePoints,
    filterBlockOps,
    historyAttachment,
    withChainSyncFollower,
    withChainSyncFollowerUsing,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    ApplyConflict,
    IndexerHandle (..),
    liveUtxoHandler,
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import ChainFollower (Intersector (..))
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    readTVar,
    writeTVar,
 )
import Control.Exception (ErrorCall (..), try)
import Control.Tracer (Tracer (..), nullTracer, traceWith)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Ouroboros.Consensus.Block.EBB (
    IsEBB (..),
 )
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldReturn,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer.Follower" $ do
        describe "withChainSyncFollower" $ do
            it
                "uses a configured start point for cold-boot\
                \ intersection"
                $ do
                    let startSlot = SlotNo 5_000_000
                        startHash =
                            BlockHash (BS.replicate 32 0x42)
                        cfg =
                            (mkCfg "unused.sock")
                                { csStartPoint =
                                    Just (startSlot, startHash)
                                }
                    coldBootResumePoints cfg
                        `shouldBe` [toHeaderPoint startSlot startHash]

            it
                "brings up against a caller-owned\
                \ in-memory IndexerHandle and exposes a\
                \ FollowerHandle whose initial Readiness\
                \ has no processed/tip slot yet"
                $ withInMemoryIndexer
                $ \idx ->
                    withSystemTempDirectory
                        "follower-spec"
                        $ \dir -> do
                            let cfg = mkCfg (dir <> "/missing.sock")
                            withChainSyncFollower
                                nullN2CTracer
                                cfg
                                idx
                                $ \fh -> do
                                    r <-
                                        atomically
                                            (fhReadiness fh)
                                    rProcessedSlot r
                                        `shouldBe` Nothing
                                    rTipSlot r `shouldBe` Nothing

            it
                "lets the caller continue to write the\
                \ same IndexerHandle via applyAtSlot\
                \ and read it back via snapshotAt while\
                \ the follower thread is alive"
                $ withInMemoryIndexer
                $ \idx ->
                    withSystemTempDirectory
                        "follower-spec"
                        $ \dir -> do
                            let cfg = mkCfg (dir <> "/missing.sock")
                                addr = Address "addr-bytes"
                                txin =
                                    TxIn
                                        (BS.replicate 32 0xAA)
                                        0
                                txout = TxOut "txout-1"
                                bh =
                                    BlockHash
                                        (BS.replicate 32 0xBB)
                            withChainSyncFollower
                                nullN2CTracer
                                cfg
                                idx
                                $ \fh -> do
                                    applyAtSlot
                                        idx
                                        (SlotNo 10)
                                        bh
                                        [ UtxoCreate
                                            txin
                                            addr
                                            txout
                                        ]
                                    snap <- snapshotAt idx addr
                                    snap
                                        `shouldBe` [(txin, txout)]
                                    -- fhAsync is exposed so the
                                    -- caller may 'link' it; we
                                    -- only assert it's typed
                                    -- correctly (no NDJSON
                                    -- server is started — the
                                    -- API signature has no
                                    -- listen-socket parameter).
                                    let _follower ::
                                            Async.Async ()
                                        _follower = fhAsync fh
                                    pure ()

            it
                "surfaces configured block and tip tracers\
                \ to the chain-sync runner"
                $ withInMemoryIndexer
                $ \idx ->
                    withSystemTempDirectory
                        "follower-spec"
                        $ \dir -> do
                            blockSeen <- newTVarIO False
                            tipSlots <- newTVarIO []
                            let cfg =
                                    (mkCfg (dir <> "/unused.sock"))
                                        { csBlockTracer =
                                            Tracer $
                                                \_ ->
                                                    atomically $
                                                        writeTVar
                                                            blockSeen
                                                            True
                                        , csTipTracer =
                                            Tracer $
                                                \slot ->
                                                    atomically $
                                                        modifyTVar'
                                                            tipSlots
                                                            (slot :)
                                        }
                                runner
                                    _epochSlots
                                    _magic
                                    _sock
                                    blockTracer
                                    tipTracer
                                    _intersector
                                    _points = do
                                        traceWith
                                            blockTracer
                                            ( error
                                                "block tracer test\
                                                \ payload is not\
                                                \ evaluated"
                                            )
                                        traceWith
                                            tipTracer
                                            (Network.SlotNo 123)
                                        pure (Right ())
                            withChainSyncFollowerUsing
                                runner
                                nullN2CTracer
                                cfg
                                idx
                                $ \_fh -> do
                                    observedTips <-
                                        atomically $ do
                                            seen <- readTVar blockSeen
                                            tips <- readTVar tipSlots
                                            check
                                                ( seen
                                                    && not (null tips)
                                                )
                                            pure tips
                                    observedTips
                                        `shouldBe` [Network.SlotNo 123]

        describe "warm-boot no-intersection" $ do
            it
                "offers the stored points and ignores\
                \ csStartPoint on a warm boot"
                $ withInMemoryIndexer
                $ \idx -> do
                    warmUp idx
                    (offered, _) <-
                        probeNoIntersection configuredPointCfg idx
                    offered `shouldBe` [toHeaderPoint (SlotNo 10) blk1]

            it
                "retries with the configured start point on a\
                \ cold boot"
                $ withInMemoryIndexer
                $ \idx -> do
                    (offered, outcome) <-
                        probeNoIntersection configuredPointCfg idx
                    offered `shouldBe` [configuredPoint]
                    outcome `shouldBe` Right [configuredPoint]

            it
                "offers the configured start point instead of the\
                \ stored points when the history store has no cursor"
                $ withInMemoryIndexer
                $ \idx ->
                    withInMemoryHistoryIndexer $ \histIdx -> do
                        warmUp idx
                        (offered, _) <-
                            probeNoIntersection
                                (cursorlessHistoryCfg histIdx)
                                idx
                        offered `shouldBe` [configuredPoint]

            it
                "fails closed naming divergence beyond k with its\
                \ recovery, on every warm path"
                $ onWarmPaths (missingFrom divergenceRoute)
                    `shouldReturn` everyWarmPath []

            it
                "fails closed naming a store younger than the\
                \ rollback depth with its recovery, on every warm\
                \ path"
                $ onWarmPaths (missingFrom youngStoreRoute)
                    `shouldReturn` everyWarmPath []

            it
                "fails closed with exactly one start-point claim,\
                \ the cold boot after a wipe, on every warm path"
                $ onWarmPaths startPointClaims
                    `shouldReturn` everyWarmPath ([], 1)

        describe "filterBlockOps (interest-set semantics)" $ do
            it
                "skips an EBB before a regular block at the\
                \ same slot"
                $ withInMemoryIndexer
                $ \idx -> do
                    result <- try @ApplyConflict $ do
                        ebbApplied <-
                            applyBlockOps
                                idx
                                IsEBB
                                (SlotNo 0)
                                blk1
                                []
                        blockApplied <-
                            applyBlockOps
                                idx
                                IsNotEBB
                                (SlotNo 0)
                                blk2
                                [UtxoCreate txInA addrA outA]
                        pure (ebbApplied, blockApplied)
                    result `shouldBe` Right (False, True)
                    snapA <- snapshotAt idx addrA
                    snapA `shouldBe` [(txInA, outA)]

            it
                "keeps UtxoCreate ops at addresses in the\
                \ interest set and drops the rest"
                $ withInMemoryIndexer
                $ \idx -> do
                    let set = Set.fromList [addrA]
                        ops =
                            [ UtxoCreate txInA addrA outA
                            , UtxoCreate txInB addrB outB
                            , UtxoCreate txInC addrC outC
                            ]
                    applyAtSlot
                        idx
                        (SlotNo 10)
                        blk1
                        (filterBlockOps (IndexAddressSet set) ops)
                    snapA <- snapshotAt idx addrA
                    snapA `shouldBe` [(txInA, outA)]

            it
                "leaves UtxoCreate ops at addresses outside\
                \ the interest set unstored — snapshotAt\
                \ returns []"
                $ withInMemoryIndexer
                $ \idx -> do
                    let set = Set.fromList [addrA]
                        ops =
                            [ UtxoCreate txInA addrA outA
                            , UtxoCreate txInB addrB outB
                            , UtxoCreate txInC addrC outC
                            ]
                    applyAtSlot
                        idx
                        (SlotNo 10)
                        blk1
                        (filterBlockOps (IndexAddressSet set) ops)
                    snapB <- snapshotAt idx addrB
                    snapB `shouldBe` []
                    snapC <- snapshotAt idx addrC
                    snapC `shouldBe` []

            it
                "always processes UtxoSpend on a stored\
                \ entry — the entry disappears from the\
                \ snapshot"
                $ withInMemoryIndexer
                $ \idx -> do
                    let set = Set.fromList [addrA]
                    applyAtSlot
                        idx
                        (SlotNo 10)
                        blk1
                        ( filterBlockOps
                            (IndexAddressSet set)
                            [UtxoCreate txInA addrA outA]
                        )
                    applyAtSlot
                        idx
                        (SlotNo 11)
                        blk2
                        ( filterBlockOps
                            (IndexAddressSet set)
                            [UtxoSpend txInA]
                        )
                    snapA <- snapshotAt idx addrA
                    snapA `shouldBe` []

            it
                "always processes UtxoSpend on a previously-\
                \filtered (never stored) entry — no error,\
                \ other addresses unaffected"
                $ withInMemoryIndexer
                $ \idx -> do
                    let set = Set.fromList [addrA]
                    applyAtSlot
                        idx
                        (SlotNo 10)
                        blk1
                        ( filterBlockOps
                            (IndexAddressSet set)
                            [ UtxoCreate txInA addrA outA
                            , UtxoCreate txInB addrB outB
                            ]
                        )
                    -- spend the filtered-out addrB entry —
                    -- must be a clean no-op.
                    applyAtSlot
                        idx
                        (SlotNo 11)
                        blk2
                        ( filterBlockOps
                            (IndexAddressSet set)
                            [UtxoSpend txInB]
                        )
                    snapA <- snapshotAt idx addrA
                    snapA `shouldBe` [(txInA, outA)]
                    snapB <- snapshotAt idx addrB
                    snapB `shouldBe` []

            it
                "IndexAll preserves every UtxoCreate\
                \ regardless of address (current daemon\
                \ behavior)"
                $ withInMemoryIndexer
                $ \idx -> do
                    let ops =
                            [ UtxoCreate txInA addrA outA
                            , UtxoCreate txInB addrB outB
                            ]
                    applyAtSlot
                        idx
                        (SlotNo 10)
                        blk1
                        (filterBlockOps IndexAll ops)
                    snapA <- snapshotAt idx addrA
                    snapA `shouldBe` [(txInA, outA)]
                    snapB <- snapshotAt idx addrB
                    snapB `shouldBe` [(txInB, outB)]

        describe "tip-distance phase transition" $ do
            it
                "writes sentinel rows while far from tip and\
                \ full rollback rows once within k"
                $ withInMemoryIndexer
                $ \idx -> do
                    let k = 2
                        tip = Network.SlotNo 10
                        withinWindow (SlotNo slot) =
                            Network.unSlotNo tip >= slot
                                && Network.unSlotNo tip - slot
                                    <= fromIntegral k
                        step slot bh ops state = do
                            (state', _processed) <-
                                processFollowerBlock
                                    idx
                                    state
                                    k
                                    (withinWindow slot)
                                    slot
                                    bh
                                    ops
                            pure state'

                    state0 <- newFollowerState idx True
                    state1 <-
                        step
                            (SlotNo 1)
                            blk1
                            [UtxoCreate txInA addrA outA]
                            state0
                    state2 <-
                        step
                            (SlotNo 2)
                            blk2
                            [UtxoCreate txInB addrB outB]
                            state1
                    restorationHistory <- getRollbackHistory idx
                    fmap (rpInverses . snd) restorationHistory
                        `shouldBe` [[], []]
                    fmap (rpMeta . snd) restorationHistory
                        `shouldBe` [Nothing, Nothing]
                    snapshotAt idx addrA
                        `shouldReturn` [(txInA, outA)]
                    snapshotAt idx addrB
                        `shouldReturn` [(txInB, outB)]

                    state3 <-
                        step
                            (SlotNo 8)
                            blk3
                            [UtxoCreate txInC addrC outC]
                            state2
                    _state4 <-
                        step
                            (SlotNo 9)
                            blk4
                            [UtxoSpend txInC]
                            state3

                    history <- getRollbackHistory idx
                    -- The spend inverse carries the creating block's
                    -- provenance (slot 8 / blk3) since the restore op.
                    fmap (rpInverses . snd) history
                        `shouldBe` [
                                       [ [UtxoSpend txInC]
                                       ]
                                   ,
                                       [
                                           [ UtxoRestore
                                                txInC
                                                addrC
                                                outC
                                                (SlotNo 8)
                                                blk3
                                           ]
                                       ]
                                   ]
                    fmap (rpMeta . snd) history
                        `shouldBe` [ Just blk3
                                   , Just blk4
                                   ]
                    snapshotAt idx addrA
                        `shouldReturn` [(txInA, outA)]
                    snapshotAt idx addrB
                        `shouldReturn` [(txInB, outB)]
                    snapshotAt idx addrC
                        `shouldReturn` []

-- ---------------------------------------------------------------------------
-- Helpers + interest-set test fixtures

{- | Test 'ChainSyncConfig' parameterised on the relay
socket path. Defaults match the existing 'DaemonSpec.testCfg'
shape so the field set the daemon needs is exercised here
too.
-}
mkCfg :: FilePath -> ChainSyncConfig
mkCfg sock =
    ChainSyncConfig
        { csRelaySocket = sock
        , csNetworkMagic = NetworkMagic 42
        , csByronEpochSlots = 86_400
        , csStartPoint = Nothing
        , csReadyThresholdSlots = 5
        , csSecurityParamK = 432
        , csReconnectPolicy = defaultReconnectPolicy
        , csProbeConfig = defaultProbeConfig
        , csInterestSet = IndexAll
        , csHandlers = liveUtxoHandler IndexAll :| []
        , csBlockTracer = nullTracer
        , csTipTracer = nullTracer
        , csHistory = Nothing
        }

{- | Run the follower bring-up against an injected
chain-sync runner whose node offers no intersection.
Returns the resume points the follower offered and the
outcome of its own 'intersectNotFound': the retry points
on a cold boot, the raised 'ErrorCall' on a warm boot.
-}
probeNoIntersection ::
    ChainSyncConfig ->
    IndexerHandle ->
    IO ([HeaderPoint], Either ErrorCall [HeaderPoint])
probeNoIntersection cfg idx = do
    observed <- newIORef Nothing
    let runner _ _ _ _ _ intersector points = do
            outcome <- try $ snd <$> intersectNotFound intersector
            writeIORef observed (Just (points, outcome))
            pure (Right ())
    withChainSyncFollowerUsing runner nullN2CTracer cfg idx $
        Async.wait . fhAsync
    readIORef observed
        >>= maybe (error "chain-sync runner was not invoked") pure

{- | Every way a warm store reaches @intersectNotFound@:
offering its stored points, and offering the configured
start point because an attached history store has no
cursor yet. Each path runs on fresh stores and yields
@inspect@ of its fail-closed message, or a 'Left' naming
the retry it took instead of failing closed.
-}
onWarmPaths ::
    (String -> a) -> IO [(String, Either String a)]
onWarmPaths inspect =
    traverse
        run
        [ ("stored points offered", const configuredPointCfg)
        , ("history store without a cursor", cursorlessHistoryCfg)
        ]
  where
    run (path, mkCfgWith) =
        withInMemoryIndexer $ \idx ->
            withInMemoryHistoryIndexer $ \histIdx -> do
                warmUp idx
                (_, outcome) <-
                    probeNoIntersection (mkCfgWith histIdx) idx
                pure
                    ( path
                    , either
                        (\(ErrorCall message) -> Right (inspect message))
                        (\retry -> Left ("retried with " <> show retry))
                        outcome
                    )

-- | The expected 'onWarmPaths' result: @a@ on every path.
everyWarmPath :: a -> [(String, Either String a)]
everyWarmPath a =
    [ ("stored points offered", Right a)
    , ("history store without a cursor", Right a)
    ]

-- | The phrases a message lacks.
missingFrom :: [String] -> String -> [String]
missingFrom phrases message =
    filter (not . (`isInfixOf` message)) phrases

-- | The phrases a message carries.
presentIn :: [String] -> String -> [String]
presentIn phrases message = filter (`isInfixOf` message) phrases

-- | Route (a) and its recovery.
divergenceRoute :: [String]
divergenceRoute =
    [ "diverged from the node beyond the security parameter k"
    , "Wipe the indexer DB and rebuild"
    , "restart against a node whose chain still includes one\
      \ of the saved points"
    ]

-- | Route (b) and its recovery.
youngStoreRoute :: [String]
youngStoreRoute =
    [ "younger than the rollback depth"
    , "cold-started inside the volatile window"
    , "rolled back past"
    , "Wipe the indexer DB and start again"
    , "A wiped store cold-boots from the configured start point"
    , "older than the rollback depth (or start from Origin)"
    ]

{- | Mentions of the 'csStartPoint' field, and the number
of start-point claims; the message may make one, that a
wiped store cold-boots from the configured start point.
-}
startPointClaims :: String -> ([String], Int)
startPointClaims message =
    ( presentIn ["csStartPoint"] message
    , length (filter ("start point" `isPrefixOf`) (tails message))
    )

-- | A warm configuration whose history store has no cursor.
cursorlessHistoryCfg :: HistoryIndexer -> ChainSyncConfig
cursorlessHistoryCfg histIdx =
    configuredPointCfg
        { csHistory =
            Just $ historyAttachment (\_ _ -> Nothing) histIdx
        }

-- | Make the store warm: one applied block, one resume point.
warmUp :: IndexerHandle -> IO ()
warmUp idx = do
    applyAtSlot idx (SlotNo 10) blk1 []
    getResumePoints idx `shouldReturn` [(SlotNo 10, blk1)]

configuredPointCfg :: ChainSyncConfig
configuredPointCfg =
    (mkCfg "unused.sock")
        { csStartPoint = Just (SlotNo 5_000_000, configuredHash)
        }

configuredPoint :: HeaderPoint
configuredPoint = toHeaderPoint (SlotNo 5_000_000) configuredHash

configuredHash :: BlockHash
configuredHash = BlockHash (BS.replicate 32 0x42)

toHeaderPoint :: SlotNo -> BlockHash -> HeaderPoint
toHeaderPoint (SlotNo slot) (BlockHash hashBytes) =
    Network.Point
        ( Network.Point.At
            ( Network.Point.Block
                (Network.SlotNo slot)
                (OneEraHash (SBS.toShort hashBytes))
            )
        )

-- Three distinct test addresses (1-byte tag plus padding
-- so they're distinguishable on the wire).
addrA, addrB, addrC :: Address
addrA = Address (BS.replicate 29 0xAA)
addrB = Address (BS.replicate 29 0xBB)
addrC = Address (BS.replicate 29 0xCC)

-- Three distinct test TxIns at indices 0..2 of three fake
-- producing transactions.
txInA, txInB, txInC :: TxIn
txInA = TxIn (BS.replicate 32 0x01) 0
txInB = TxIn (BS.replicate 32 0x02) 0
txInC = TxIn (BS.replicate 32 0x03) 0

-- Three distinct test TxOuts (raw byte tags).
outA, outB, outC :: TxOut
outA = TxOut "tag-A"
outB = TxOut "tag-B"
outC = TxOut "tag-C"

-- Distinct block hashes for the apply-block slots used
-- across the filter and phase scenarios.
blk1, blk2, blk3, blk4 :: BlockHash
blk1 = BlockHash (BS.replicate 32 0xF1)
blk2 = BlockHash (BS.replicate 32 0xF2)
blk3 = BlockHash (BS.replicate 32 0xF3)
blk4 = BlockHash (BS.replicate 32 0xF4)
