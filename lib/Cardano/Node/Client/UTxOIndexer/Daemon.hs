{- |
Module      : Cardano.Node.Client.UTxOIndexer.Daemon
Description : Daemon entrypoint — wires ChainSync, Indexer, Server
License     : Apache-2.0

Composes the four pieces the daemon needs:

* 'IndexerHandle' from @utxo-indexer-lib@ — the in-memory
  address->UTxO index plus its rollback log and await
  waiters.
* 'Cardano.Node.Client.UTxOIndexer.BlockExtract.extractBlock'
  — block→@(slot, [UtxoOp])@ era-polymorphic decoder.
* 'Cardano.Node.Client.UTxOIndexer.Server.runServer' —
  NDJSON Unix-socket server.
* 'Cardano.Node.Client.N2C.ChainSync.runChainSyncN2C' —
  the chain-sync follower itself.

A 'TVar' 'ReadyStatus' is updated as blocks land so the
@ready@ NDJSON request reflects the daemon's current
catch-up state.
-}
module Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )
import Cardano.Node.Client.UTxOIndexer.BlockExtract (extractBlock)
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    withInMemoryIndexer,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Probe (ProbeConfig)
import Cardano.Node.Client.UTxOIndexer.Reconnect (
    ReconnectPolicy,
    UpstreamStatus (..),
    runReconnectLoop,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Trace (
    IndexerEvent (..),
    StopReason (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    BlockHash (..),
    SlotNo (..),
 )
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM (
    TVar,
    atomically,
    newTVarIO,
    readTVarIO,
    writeTVar,
 )
import Control.Exception (onException)
import Control.Monad (void)
import Control.Tracer (Tracer, nullTracer, traceWith)
import Data.ByteString.Short qualified as SBS
import Data.Word (Word32, Word64)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point

{- | Daemon runtime configuration. Plain Haskell record;
the CLI-parsing in @Main@ produces this.
-}
data DaemonConfig = DaemonConfig
    { dcRelaySocket :: FilePath
    , dcListenSocket :: FilePath
    , dcNetworkMagic :: Word32
    , dcByronEpochSlots :: Word64
    , dcReadyThresholdSlots :: Word64
    , dcSecurityParamK :: Int
    -- ^ Cardano security parameter @k@ — the
    -- rollback-log entry count is capped at this many,
    -- and older entries are dropped after each apply.
    , dcDbPath :: Maybe FilePath
    -- ^ When 'Just', open the indexer against a RocksDB
    -- database at this path; state survives process
    -- restart. When 'Nothing', use the volatile
    -- in-memory backend (intended for tests).
    , dcReconnectPolicy :: !ReconnectPolicy
    -- ^ Backoff policy for the in-process reconnect
    -- supervisor. Defaults via 'defaultReconnectPolicy'.
    , dcProbeConfig :: !ProbeConfig
    -- ^ Configuration for the LSQ tip probe that gates
    -- each reconnect attempt. Defaults via
    -- 'defaultProbeConfig' — chain-replay-tolerant
    -- (unbounded total timeout).
    }
    deriving stock (Show)

{- | Open the indexer (RocksDB if @dcDbPath@ is set,
in-memory otherwise), start the NDJSON server and the
chain-sync follower, and block.

The chain-sync follower is wrapped in 'runReconnectLoop'
(a probe-then-connect supervisor on top of
'Control.Retry'); when the upstream relay disconnects,
the supervisor catches the exception, probes the relay
via LSQ until ready, and re-attempts chain-sync. The
listen socket and indexer state persist across the
reconnect window.

The caller-provided 'Tracer' receives an 'IndexerStarted'
on entry and an 'IndexerStopped' on exit (both clean
termination and async cancellation), plus all
reconnect-supervisor and probe events between.
-}
runDaemon :: Tracer IO IndexerEvent -> DaemonConfig -> IO ()
runDaemon tracer cfg = do
    onStart
    -- 'onException' propagates the async exception after
    -- emitting IndexerStopped, without masking the body
    -- (which would interfere with the supervisor's STM
    -- callbacks and threadDelay).
    runBody `onException` onStop StoppedAsync
    onStop StoppedNormally
  where
    runBody = do
        readyVar <- newTVarIO initialReady
        withIndexer (dcDbPath cfg) $ \idx -> do
            let getReady = readTVarIO readyVar
                -- Recompute resume points on each retry so the
                -- supervisor always feeds the latest persisted
                -- state into chain-sync.
                chainSession = do
                    bootMode <- detectBootMode idx
                    let resumePoints = case bootMode of
                            ColdBoot ->
                                [Network.Point Network.Point.Origin]
                            WarmBoot ps -> fmap toHeaderPoint ps
                    runChainSyncN2C
                        (EpochSlots (dcByronEpochSlots cfg))
                        (NetworkMagic (dcNetworkMagic cfg))
                        (dcRelaySocket cfg)
                        ( mkChainSyncN2C
                            nullTracer
                            nullTracer
                            (mkIntersector bootMode cfg readyVar idx)
                            resumePoints
                        )
                -- Status sink and processed-slot getter are wired
                -- in T009. For now the supervisor swallows status
                -- updates and returns Nothing for the resume slot.
                noopSetStatus :: UpstreamStatus -> IO ()
                noopSetStatus _ = pure ()
                noopGetSlot :: IO (Maybe SlotNo)
                noopGetSlot = pure Nothing
                chainAction =
                    runReconnectLoop
                        tracer
                        (dcReconnectPolicy cfg)
                        (dcProbeConfig cfg)
                        (NetworkMagic (dcNetworkMagic cfg))
                        (dcRelaySocket cfg)
                        noopSetStatus
                        noopGetSlot
                        chainSession
                serverAction =
                    runServer (dcListenSocket cfg) idx getReady
            concurrently_ (void chainAction) serverAction
    onStart =
        traceWith
            tracer
            (IndexerStarted (dcListenSocket cfg) (dcDbPath cfg))
    onStop r = traceWith tracer (IndexerStopped r)
    initialReady =
        ReadyStatus
            { rsReady = False
            , rsTipSlot = Nothing
            , rsProcessedSlot = Nothing
            , rsSlotsBehind = Nothing
            , rsUpstream = UpstreamConnected
            }
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) = withRocksDBIndexer path

{- | Boot classification: cold (no retained rollback
points — fresh DB or in-memory) vs. warm (one or more
retained points from a prior run).

The two are treated differently on @intersectNotFound@:
cold boots retry with @[Origin]@ (transient races during
node startup are normal), warm boots fail closed (their
saved chain has diverged from the node beyond the
security parameter k, and origin-replay over the
populated DB would mix histories).
-}
data BootMode
    = ColdBoot
    | WarmBoot ![(SlotNo, BlockHash)]

detectBootMode :: IndexerHandle -> IO BootMode
detectBootMode idx = do
    pairs <- getResumePoints idx
    pure $ case pairs of
        [] -> ColdBoot
        ps -> WarmBoot ps

{- | Convert a stored @(slot, blockhash)@ pair into a
'HeaderPoint' chain-sync can negotiate against.
-}
toHeaderPoint :: (SlotNo, BlockHash) -> HeaderPoint
toHeaderPoint (SlotNo s, BlockHash bh) =
    Network.Point
        ( Network.Point.At
            ( Network.Point.Block
                (Network.SlotNo s)
                (OneEraHash (SBS.toShort bh))
            )
        )

mkIntersector ::
    BootMode ->
    DaemonConfig ->
    TVar ReadyStatus ->
    IndexerHandle ->
    Intersector HeaderPoint Network.SlotNo Fetched
mkIntersector bootMode cfg readyVar idx = self
  where
    self =
        Intersector
            { intersectFound = \point -> do
                -- Roll persistent state back to the
                -- intersected slot before following. No-op
                -- when the newest saved point intersects
                -- (rollbackTo's RollbackCol walk finds nothing
                -- strictly past the target); required when an
                -- older retained point intersected because of
                -- an offline rollback.
                rollbackTo idx (slotOfPoint point)
                pure (mkFollower cfg readyVar idx)
            , intersectNotFound = case bootMode of
                ColdBoot ->
                    -- Cold-boot races during node startup are
                    -- normal; retry with [Origin]. Origin
                    -- always intersects once the node's chain
                    -- is loaded.
                    pure (self, [Network.Point Network.Point.Origin])
                WarmBoot _ ->
                    -- Amended #86: never origin-replay over a
                    -- populated DB — that mixes chain histories.
                    -- Fail closed; manual recovery is wiping
                    -- --db-path. A future flag could opt into
                    -- automatic 'Rollbacks.armageddonCleanup'-
                    -- driven rebuild.
                    error
                        "utxo-indexer: chain-sync found no \
                        \intersection against any retained \
                        \rollback-log point. The saved chain \
                        \has diverged from the node beyond \
                        \the security parameter k. Wipe \
                        \--db-path to rebuild from Origin, \
                        \or restart against a node whose \
                        \chain still includes one of the \
                        \saved points."
            }

{- | Convert a chain-sync 'HeaderPoint' to the indexer's
'SlotNo'. Origin maps to @SlotNo 0@; that's only used in
the unusual case where chain-sync intersects at Origin
itself, in which case 'rollbackTo' on @SlotNo 0@ is a
no-op against an already-cold DB.
-}
slotOfPoint :: HeaderPoint -> SlotNo
slotOfPoint p =
    case Network.pointSlot p of
        Network.Point.Origin -> SlotNo 0
        Network.Point.At s -> SlotNo (Network.unSlotNo s)

mkFollower ::
    DaemonConfig ->
    TVar ReadyStatus ->
    IndexerHandle ->
    Follower HeaderPoint Network.SlotNo Fetched
mkFollower cfg readyVar idx = self
  where
    self =
        Follower
            { rollForward = \fetched tip -> do
                let (slot, ops) = extractBlock (fetchedBlock fetched)
                    bh = pointToBlockHash (fetchedPoint fetched)
                -- 'applyAtSlot' is replay-aware: same slot
                -- + same blockhash is a silent no-op; same
                -- slot + different blockhash throws
                -- 'ApplyConflict'. Phase A surfaces that
                -- crash to the caller; phase B (#86) replaces
                -- it with a rollback to an older retained
                -- point.
                applyAtSlot idx slot bh ops
                _ <- pruneRollbacks idx (dcSecurityParamK cfg)
                updateReady cfg readyVar slot tip
                pure self
            , rollBackward = \point -> do
                let slot = case Network.pointSlot point of
                        Network.Point.Origin -> SlotNo 0
                        Network.Point.At s -> SlotNo (Network.unSlotNo s)
                rollbackTo idx slot
                pure (Progress self)
            }

{- | Pull the block hash bytes out of an
'OneEraHash'-shaped 'HeaderPoint'. Origin (no block)
maps to an empty 'BlockHash'.
-}
pointToBlockHash :: HeaderPoint -> BlockHash
pointToBlockHash p =
    case p of
        Network.Point Network.Point.Origin -> BlockHash mempty
        Network.Point (Network.Point.At (Network.Point.Block _ h)) ->
            BlockHash (SBS.fromShort (getOneEraHash h))

updateReady ::
    DaemonConfig ->
    TVar ReadyStatus ->
    SlotNo ->
    Network.SlotNo ->
    IO ()
updateReady cfg readyVar (SlotNo processed) tipNet =
    let tip = Network.unSlotNo tipNet
        behind = if tip > processed then tip - processed else 0
        ready = behind <= dcReadyThresholdSlots cfg
        rs =
            ReadyStatus
                { rsReady = ready
                , rsTipSlot = Just (SlotNo tip)
                , rsProcessedSlot = Just (SlotNo processed)
                , rsSlotsBehind = Just behind
                , -- A roll-forward implies the supervisor's
                  -- chain-sync session is alive. T009 wires the
                  -- supervisor's status sink into the same
                  -- TVar so transient flips are corrected on
                  -- the next event.
                  rsUpstream = UpstreamConnected
                }
     in atomically (writeTVar readyVar rs)
