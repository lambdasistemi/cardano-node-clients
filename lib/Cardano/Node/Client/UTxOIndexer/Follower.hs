{- |
Module      : Cardano.Node.Client.UTxOIndexer.Follower
Description : Chain-sync follower as a bracketed resource action
License     : Apache-2.0

Standalone bring-up of the chain-sync follower against a
**caller-owned** 'IndexerHandle'. Pairs the existing
@runChainSyncN2C@ with @runReconnectLoop@ in exactly the
shape the bundled daemon was using internally, and exposes
the result as a 'withChainSyncFollower' resource action so
downstream consumers can run the follower without also
spinning up the NDJSON socket server.

= Motivation

The bundled daemon (@Cardano.Node.Client.UTxOIndexer.Daemon.runDaemon@)
opens its own 'IndexerHandle' internally and bundles an
NDJSON Unix-socket server alongside the follower. The
@amaru-treasury-tx-api@ HTTP container embeds the indexer
in-process and queries it via 'snapshotAt' directly — it
needs:

* to **own** the 'IndexerHandle' so it can pass it to its
  request handlers (RocksDB is single-writer; the daemon
  can't open a second handle on the same store), and
* no NDJSON server (it doesn't query over a socket).

'withChainSyncFollower' is the primitive that satisfies
both. @runDaemon@ is re-implemented atop it without any
public-facing change.

= Relationship to @ReadyStatus@

The bundled daemon's wire format (the @ready@ NDJSON
response shape) is owned by
'Cardano.Node.Client.UTxOIndexer.Server.ReadyStatus'. This
module exposes a leaner 'Readiness' record that the daemon
translates into 'ReadyStatus' at read time, plus the same
'UpstreamStatus' surface so the daemon can preserve the
disconnect details on the wire.

The literal proposal in
[lambdasistemi\/cardano-node-clients#156](https://github.com/lambdasistemi/cardano-node-clients/issues/156)
used a single @rUpstreamUp :: Bool@ flag and strict
@SlotNo@ fields; the actual codebase needs the richer
'UpstreamStatus' (to retain disconnect reasons through the
daemon's NDJSON wire) and 'Maybe' slot fields (to
distinguish "no rollForward yet" from "rolled forward to
slot 0"). The proposal was relaxed accordingly per the
slice brief's "actual codebase wins" guidance.

= Interest-set compatibility

'InterestSet' and 'filterBlockOps' are re-exported from
"Cardano.Node.Client.UTxOIndexer.Indexer". Existing consumers can
continue importing them from this follower module. New storage
filtering is applied by the UTxO 'liveUtxoHandler' at the generic
block-indexer handler boundary, so the follower passes raw extracted
operations into 'processFollowerBlock'.

= Handler pipeline

'ChainSyncConfig.csHandlers' is the block-indexer handler pipeline
used by the follower after each block is extracted into @[UtxoOp]@.
The historical UTxO indexer behavior is preserved by configuring
@csHandlers = liveUtxoHandler csInterestSet :| []@.

Consumers that add another handler should keep 'liveUtxoHandler' in
the list when they still need the normal UTxO columns populated for
'snapshotAt', 'awaitTxIn', resume points, and rollback. Additional
handlers run through the same follow and rollback fanout as the live
UTxO handler, so they observe the same follower phase transitions.

The follower obtains its initial 'IndexerFollowerState' from
'IndexerHandle.newFollowerState' without changing that handle field's
historical shape, then retargets the phase handlers with
'withFollowerHandlers'. That helper is the public extension point for
applying a configured handler list to follower state.
-}
module Cardano.Node.Client.UTxOIndexer.Follower (
    -- * Configuration
    ChainSyncConfig (..),
    coldBootResumePoints,

    -- * Interest-set filter
    -- $interestSet
    InterestSet (..),
    filterBlockOps,
    applyBlockOps,

    -- * Readiness state
    Readiness (..),
    initialReadiness,

    -- * Handle
    FollowerHandle (..),

    -- * Bring-up
    ChainSyncRunner,
    withChainSyncFollower,
    withChainSyncFollowerUsing,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.BlockIndexer.Handler (
    IndexerHandler,
 )
import Cardano.Node.Client.BlockIndexer.Readiness qualified as BI
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )
import Cardano.Node.Client.N2C.Probe (ProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy,
    UpstreamStatus (..),
    runReconnectLoop,
 )
import Cardano.Node.Client.N2C.Trace (N2CEvent)
import Cardano.Node.Client.Types (Block)
import Cardano.Node.Client.UTxOIndexer.BlockExtract (
    extractBlock,
 )
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerFollowerState,
    IndexerHandle (..),
    InterestSet (..),
    filterBlockOps,
    withFollowerHandlers,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
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
import Control.Concurrent.Async (Async, withAsync)
import Control.Concurrent.STM (
    STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
 )
import Control.Exception (SomeException)
import Control.Monad (void)
import Control.Tracer (Tracer)
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Ouroboros.Consensus.Block.Abstract (
    blockToIsEBB,
 )
import Ouroboros.Consensus.Block.EBB (
    IsEBB (..),
 )
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Point qualified as Network.Point

-- ---------------------------------------------------------------------------
-- Types

{- | Configuration for the chain-sync follower. Carries the
parameters @runDaemon@ historically derived from its own
'DaemonConfig'; callers building this directly populate
the fields themselves.
-}
data ChainSyncConfig = ChainSyncConfig
    { csRelaySocket :: !FilePath
    -- ^ Path to the upstream node's Unix socket.
    , csNetworkMagic :: !NetworkMagic
    -- ^ Network magic for the chain-sync handshake.
    , csByronEpochSlots :: !Word64
    -- ^ Byron @EpochSlots@, used by the chain-sync codec
    -- to decode pre-Shelley blocks.
    , csStartPoint :: !(Maybe (SlotNo, BlockHash))
    -- ^ Optional explicit cold-boot intersection point.
    -- 'Nothing' preserves the historical Origin boot; a
    -- concrete @(slot, hash)@ lets callers start from a
    -- known point instead of replaying from genesis.
    , csReadyThresholdSlots :: !Word64
    -- ^ Slot-lag threshold beyond which @ready@ flips to
    -- @False@. Plumbed through to consumers (the follower
    -- itself does not gate on this — it always applies
    -- every block it sees).
    , csSecurityParamK :: !Int
    -- ^ Cardano security parameter @k@: the rollback-log
    -- entry count is capped at this many; older entries
    -- are dropped after each apply.
    , csReconnectPolicy :: !ReconnectPolicy
    -- ^ Backoff policy for the in-process reconnect
    -- supervisor wrapped around the chain-sync session.
    , csProbeConfig :: !ProbeConfig
    -- ^ LSQ tip-probe configuration that gates each
    -- reconnect attempt — chain-replay-tolerant
    -- (unbounded total timeout) by default.
    , csInterestSet :: !InterestSet
    -- ^ Apply-time address filter (issue #158). Default
    -- 'IndexAll' preserves the prior full-chain behavior
    -- so existing daemon and reconnect tests stay green.
    -- 'IndexAddressSet' bounds the on-disk store to
    -- @O(|set|)@ entries by dropping every
    -- 'UtxoCreate' whose output address is outside the
    -- set; 'UtxoSpend' is always processed (a spend on a
    -- previously-filtered create is a clean no-op
    -- because the 'TxInCol' entry never existed).
    , csHandlers :: !(NonEmpty (IndexerHandler Cols [UtxoOp]))
    -- ^ Block-indexer storage handler pipeline used by
    -- the follower for every extracted UTxO operation
    -- batch. Use @liveUtxoHandler csInterestSet :| []@
    -- to preserve the normal UTxO columns. When adding
    -- extra handlers, keep 'liveUtxoHandler' in this list
    -- if callers still need the standard UTxO indexer
    -- reads; every handler in the list participates in
    -- the same follow and rollback fanout.
    , csBlockTracer :: !(Tracer IO Block)
    -- ^ Per-roll-forward block tracer supplied to
    -- 'mkChainSyncN2C'. Use 'nullTracer' to preserve the
    -- historical quiet behavior.
    , csTipTracer :: !(Tracer IO Network.SlotNo)
    -- ^ Per-roll-forward chain-tip slot tracer supplied
    -- to 'mkChainSyncN2C'. Use 'nullTracer' to preserve
    -- the historical quiet behavior.
    }

instance Show ChainSyncConfig where
    show cfg =
        "ChainSyncConfig"
            <> " { csRelaySocket = "
            <> show (csRelaySocket cfg)
            <> ", csNetworkMagic = "
            <> show (csNetworkMagic cfg)
            <> ", csByronEpochSlots = "
            <> show (csByronEpochSlots cfg)
            <> ", csStartPoint = "
            <> show (csStartPoint cfg)
            <> ", csReadyThresholdSlots = "
            <> show (csReadyThresholdSlots cfg)
            <> ", csSecurityParamK = "
            <> show (csSecurityParamK cfg)
            <> ", csReconnectPolicy = "
            <> show (csReconnectPolicy cfg)
            <> ", csProbeConfig = "
            <> show (csProbeConfig cfg)
            <> ", csInterestSet = "
            <> show (csInterestSet cfg)
            <> ", csHandlers = <handlers>"
            <> ", csBlockTracer = <tracer>"
            <> ", csTipTracer = <tracer>"
            <> " }"

{- $interestSet
Address filter applied to each @[UtxoOp]@ batch by the
UTxO storage handler.

= Semantics

* 'IndexAll' — pass every op through unchanged. Matches
  the pre-#158 follower; the bundled daemon binary
  always passes this, so its tests stay green.
* @'IndexAddressSet' s@ — keep 'UtxoCreate' ops whose
  output address belongs to @s@; drop the rest. ALL
  'UtxoSpend' ops are kept (the underlying indexer is
  rollback-aware: a spend on a previously-filtered
  create finds no @TxInCol@ entry and is a silent
  no-op).

= State invariant

For every query restricted to addresses in @s@ (i.e.
'snapshotAt' / 'awaitTxIn' on addresses the caller knows
are in @s@), the resulting state is byte-identical to
running the follower with 'IndexAll'. Disk grows as
@O(|s| × avg UTxOs per address × time)@ instead of
@O(entire chain UTxO set)@.

Out of scope: dynamic mutation of the set after
'withChainSyncFollower' returns the 'FollowerHandle'
(the value is captured when the follower state is created).
A future ticket can lift the field into an STM-mutable value
if multi-tenant onboarding requires it.
-}

{- | Apply a fetched block's extracted UTxO operations,
unless the consensus layer identifies it as an Epoch
Boundary Block. EBBs carry no UTxO operations and may
share their slot with the following regular Byron block,
so recording them in the rollback log would create a
same-slot, different-hash conflict on mainnet cold boot.

Returns 'True' only when the block was persisted via
'applyAtSlot'.
-}
applyBlockOps ::
    IndexerHandle ->
    IsEBB ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    IO Bool
applyBlockOps idx isEBB slot bh ops =
    case isEBB of
        IsEBB -> pure False
        IsNotEBB -> do
            applyAtSlot idx slot bh ops
            pure True

{- | UTxO follower readiness snapshot updated after every
roll-forward and on every reconnect status transition.

The 'Maybe' slot fields are 'Nothing' before the first
'rollForward' fires; once set they are preserved across
upstream disconnects (matching the bundled daemon's
existing @ReadyStatus@ retention semantics).

'rUpstream' uses the same
'Cardano.Node.Client.N2C.Reconnect.UpstreamStatus' the
reconnect supervisor publishes — downstream consumers
that only need a Bool can pattern-match
@case rUpstream r of UpstreamConnected -> True; _ ->
False@.
-}
data Readiness = Readiness
    { rProcessedSlot :: !(Maybe SlotNo)
    -- ^ Highest slot the follower has applied to the
    -- caller-owned 'IndexerHandle'. 'Nothing' before the
    -- first 'rollForward'.
    , rTipSlot :: !(Maybe SlotNo)
    -- ^ Latest tip slot observed from the upstream node.
    -- 'Nothing' before the first 'rollForward'.
    , rUpstream :: !UpstreamStatus
    -- ^ Reconnect-supervisor view of the upstream node.
    -- Carries the disconnect reason on the disconnected
    -- side.
    , rUpdatedAt :: !UTCTime
    -- ^ Wall-clock time of the last 'TVar' write.
    }
    deriving stock (Show)

{- | Handle the bracketed 'withChainSyncFollower' returns
to its action. Callers can:

* Sample the readiness snapshot non-blockingly with
  @atomically (fhReadiness h)@.
* Build STM gates on top of the readiness field — e.g.
  block until @rUpstream@ becomes
  'UpstreamConnected'.
* @'link'@ 'fhAsync' so follower exceptions propagate to
  the calling thread instead of going to a logged limbo.
-}
data FollowerHandle = FollowerHandle
    { fhReadiness :: !(STM Readiness)
    -- ^ STM action reading the current readiness
    -- snapshot.
    , fhAsync :: !(Async ())
    -- ^ The follower's supervised chain-sync thread.
    -- 'link' it to propagate exceptions; cancellation on
    -- the bracket exit is automatic.
    }

-- ---------------------------------------------------------------------------
-- Bring-up

{- | Transport seam used by 'withChainSyncFollowerUsing'.
Production code uses 'defaultChainSyncRunner'; tests can
inject a runner that observes the caller-provided tracers
without opening a real node socket.
-}
type ChainSyncRunner =
    EpochSlots ->
    NetworkMagic ->
    FilePath ->
    Tracer IO Block ->
    Tracer IO Network.SlotNo ->
    Intersector HeaderPoint Network.SlotNo Fetched ->
    [HeaderPoint] ->
    IO (Either SomeException ())

{- | Run the chain-sync follower against a caller-owned
'IndexerHandle' under a reconnect supervisor, and hand
the resulting 'FollowerHandle' to the action. The follower
thread is cancelled when the action returns.

The follower writes UTxO operations into the handle via
'applyAtSlot' and 'rollbackTo'; concurrent reads via
'snapshotAt' / 'awaitTxIn' are thread-safe (the indexer
library guarantees STM-backed read isolation).
-}
withChainSyncFollower ::
    -- | Tracer for reconnect-supervisor lifecycle events.
    Tracer IO N2CEvent ->
    ChainSyncConfig ->
    -- | Caller-owned handle the follower writes into.
    IndexerHandle ->
    (FollowerHandle -> IO a) ->
    IO a
withChainSyncFollower =
    withChainSyncFollowerCore True defaultChainSyncRunner

{- | Variant of 'withChainSyncFollower' with an injectable
chain-sync runner. The supplied runner is executed
directly, without the reconnect supervisor's node-ready
probe, so unit tests can deterministically verify that
'csBlockTracer' and 'csTipTracer' are surfaced to the N2C
chain-sync layer without opening a real node socket.
-}
withChainSyncFollowerUsing ::
    ChainSyncRunner ->
    -- | Tracer for reconnect-supervisor lifecycle events.
    Tracer IO N2CEvent ->
    ChainSyncConfig ->
    -- | Caller-owned handle the follower writes into.
    IndexerHandle ->
    (FollowerHandle -> IO a) ->
    IO a
withChainSyncFollowerUsing =
    withChainSyncFollowerCore False

withChainSyncFollowerCore ::
    Bool ->
    ChainSyncRunner ->
    -- | Tracer for reconnect-supervisor lifecycle events.
    Tracer IO N2CEvent ->
    ChainSyncConfig ->
    -- | Caller-owned handle the follower writes into.
    IndexerHandle ->
    (FollowerHandle -> IO a) ->
    IO a
withChainSyncFollowerCore supervise chainSyncRunner tracer cfg idx action = do
    now <- getCurrentTime
    readinessVar <- newTVarIO (initialReadiness now)
    let chainSession = do
            bootMode <- detectBootMode idx
            let resumePoints = case bootMode of
                    ColdBoot -> coldBootResumePoints cfg
                    WarmBoot ps -> fmap toHeaderPoint ps
            chainSyncRunner
                (EpochSlots (csByronEpochSlots cfg))
                (csNetworkMagic cfg)
                (csRelaySocket cfg)
                (csBlockTracer cfg)
                (csTipTracer cfg)
                ( mkIntersector
                    bootMode
                    cfg
                    readinessVar
                    idx
                )
                resumePoints
        setUpstreamStatus newStatus = do
            tNow <- getCurrentTime
            atomically $
                modifyTVar'
                    readinessVar
                    (applyUpstreamToReadiness newStatus tNow)
        getProcessedSlot =
            rProcessedSlot <$> readTVarIO readinessVar
        chainAction =
            runReconnectLoop
                tracer
                (csReconnectPolicy cfg)
                (csProbeConfig cfg)
                (csNetworkMagic cfg)
                (csRelaySocket cfg)
                setUpstreamStatus
                getProcessedSlot
                chainSession
        directChainAction =
            void chainSession
        followerAction =
            if supervise
                then void chainAction
                else directChainAction
    withAsync followerAction $ \a ->
        action
            FollowerHandle
                { fhReadiness = readTVar readinessVar
                , fhAsync = a
                }

defaultChainSyncRunner :: ChainSyncRunner
defaultChainSyncRunner
    epochSlots
    magic
    sock
    blockTracer
    tipTracer
    intersector
    points =
        runChainSyncN2C
            epochSlots
            magic
            sock
            (mkChainSyncN2C blockTracer tipTracer intersector points)

{- | Initial 'Readiness' value at bring-up: no slots
applied yet, supervisor-reported state is
'UpstreamConnected' (the supervisor will flip it to
'UpstreamDisconnected' on the first failed probe;
matches the bundled daemon's historical initial
@ReadyStatus@).
-}
initialReadiness :: UTCTime -> Readiness
initialReadiness =
    fromBlockReadiness . BI.initialReadiness UpstreamConnected

-- ---------------------------------------------------------------------------
-- Boot mode + chain-sync resume points

{- | Boot classification: cold (no retained rollback
points — fresh DB or in-memory) vs. warm (one or more
retained points from a prior run).

The two are treated differently on @intersectNotFound@:
cold boots retry with @[Origin]@ (transient races during
node startup are normal), warm boots fail closed (their
saved chain has diverged from the node beyond the
security parameter @k@, and origin-replay over the
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

{- | Chain-sync resume points for an empty indexer. With
no configured start point the follower preserves the
historical Origin cold boot; with a configured point the
first intersection request names that concrete block.
-}
coldBootResumePoints :: ChainSyncConfig -> [HeaderPoint]
coldBootResumePoints cfg =
    case csStartPoint cfg of
        Nothing -> [Network.Point Network.Point.Origin]
        Just startPoint -> [toHeaderPoint startPoint]

-- ---------------------------------------------------------------------------
-- Intersector + per-roll Follower

mkIntersector ::
    BootMode ->
    ChainSyncConfig ->
    TVar Readiness ->
    IndexerHandle ->
    Intersector HeaderPoint Network.SlotNo Fetched
mkIntersector bootMode cfg readinessVar idx = self
  where
    self =
        Intersector
            { intersectFound = \point -> do
                -- Roll persistent state back to the
                -- intersected slot before following.
                -- No-op when the newest saved point
                -- intersects (rollbackTo's RollbackCol
                -- walk finds nothing strictly past the
                -- target); required when an older
                -- retained point intersected because of
                -- an offline rollback.
                rollbackTo idx (slotOfPoint point)
                followerState <-
                    withFollowerHandlers (csInterestSet cfg) (csHandlers cfg)
                        <$> newFollowerState idx True
                pure (mkFollower cfg readinessVar idx followerState)
            , intersectNotFound = case bootMode of
                ColdBoot ->
                    pure
                        ( self
                        , coldBootResumePoints cfg
                        )
                WarmBoot _ ->
                    -- Never origin-replay over a populated
                    -- DB — that mixes chain histories.
                    -- Fail closed; manual recovery is
                    -- wiping the database.
                    error
                        "utxo-indexer: chain-sync found no \
                        \intersection against any retained \
                        \rollback-log point. The saved chain \
                        \has diverged from the node beyond \
                        \the security parameter k. Wipe \
                        \the indexer DB to rebuild from \
                        \Origin, or restart against a node \
                        \whose chain still includes one of \
                        \the saved points."
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
        Network.Point.At s ->
            SlotNo (Network.unSlotNo s)

mkFollower ::
    ChainSyncConfig ->
    TVar Readiness ->
    IndexerHandle ->
    IndexerFollowerState ->
    Follower HeaderPoint Network.SlotNo Fetched
mkFollower cfg readinessVar idx = go
  where
    go followerState =
        Follower
            { rollForward = \fetched tip -> do
                let (slot, ops) =
                        extractBlock (fetchedBlock fetched)
                    bh =
                        pointToBlockHash
                            (fetchedPoint fetched)
                    isEBB =
                        blockToIsEBB (fetchedBlock fetched)
                    withinWindow =
                        withinStabilityWindow
                            (csSecurityParamK cfg)
                            slot
                            tip
                (nextFollowerState, _processed) <-
                    applyBlockOpsWithPhase
                        cfg
                        idx
                        followerState
                        isEBB
                        withinWindow
                        slot
                        bh
                        ops
                updateReadiness readinessVar slot tip
                pure (go nextFollowerState)
            , rollBackward = \point -> do
                let slot = case Network.pointSlot point of
                        Network.Point.Origin -> SlotNo 0
                        Network.Point.At s ->
                            SlotNo (Network.unSlotNo s)
                state' <- rollbackFollowerState idx followerState slot
                pure (Progress (go state'))
            }

withinStabilityWindow :: Int -> SlotNo -> Network.SlotNo -> Bool
withinStabilityWindow securityParamK (SlotNo blockSlot) tipSlot =
    tip >= blockSlot
        && tip - blockSlot <= fromIntegral (max 0 securityParamK)
  where
    tip = Network.unSlotNo tipSlot

{- | Apply a block via the indexer's chain-follower
Runner wrapper according to the block's distance from
the upstream tip. Far-from-tip blocks stay in restoration;
blocks inside the stability window transition to following.
-}
applyBlockOpsWithPhase ::
    ChainSyncConfig ->
    IndexerHandle ->
    IndexerFollowerState ->
    IsEBB ->
    Bool ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    IO (IndexerFollowerState, Bool)
applyBlockOpsWithPhase
    cfg
    idx
    followerState
    isEBB
    withinWindow
    slot
    bh
    ops =
        case isEBB of
            IsEBB ->
                pure (followerState, False)
            IsNotEBB ->
                processFollowerBlock
                    idx
                    followerState
                    (csSecurityParamK cfg)
                    withinWindow
                    slot
                    bh
                    ops

{- | Pull the block hash bytes out of an
'OneEraHash'-shaped 'HeaderPoint'. Origin (no block) maps
to an empty 'BlockHash'.
-}
pointToBlockHash :: HeaderPoint -> BlockHash
pointToBlockHash p =
    case p of
        Network.Point Network.Point.Origin ->
            BlockHash mempty
        Network.Point
            (Network.Point.At (Network.Point.Block _ h)) ->
                BlockHash (SBS.fromShort (getOneEraHash h))

-- ---------------------------------------------------------------------------
-- Readiness writes

{- | Record a roll-forward in the readiness 'TVar': the
follower just applied @processed@, the upstream tip is
@tip@. Implies @UpstreamConnected@ (a rollForward
necessarily means the chain-sync session is alive).
-}
updateReadiness ::
    TVar Readiness ->
    SlotNo ->
    Network.SlotNo ->
    IO ()
updateReadiness readinessVar processed tipNet = do
    now <- getCurrentTime
    let tip = SlotNo (Network.unSlotNo tipNet)
    atomically $
        writeTVar readinessVar $
            Readiness
                { rProcessedSlot = Just processed
                , rTipSlot = Just tip
                , rUpstream = UpstreamConnected
                , rUpdatedAt = now
                }

{- | Pure mapping from a reconnect-supervisor status
transition to a 'Readiness' update. Mirrors the
bundled daemon's
'Cardano.Node.Client.UTxOIndexer.Daemon.applyUpstreamStatus'
shape, but at the granularity of 'Readiness' (no derived
@rsReady@ field — that's computed at read time by the
daemon's wire converter so the threshold lives in one
place).

Slot fields are always preserved across the transition;
only 'rUpstream' and 'rUpdatedAt' are updated.
-}
applyUpstreamToReadiness ::
    UpstreamStatus -> UTCTime -> Readiness -> Readiness
applyUpstreamToReadiness newStatus now =
    fromBlockReadiness
        . BI.applyUpstreamToReadiness newStatus now
        . toBlockReadiness

toBlockReadiness :: Readiness -> BI.Readiness SlotNo UpstreamStatus
toBlockReadiness r =
    BI.Readiness
        { BI.rProcessedSlot = rProcessedSlot r
        , BI.rTipSlot = rTipSlot r
        , BI.rUpstream = rUpstream r
        , BI.rUpdatedAt = rUpdatedAt r
        }

fromBlockReadiness :: BI.Readiness SlotNo UpstreamStatus -> Readiness
fromBlockReadiness r =
    Readiness
        { rProcessedSlot = BI.rProcessedSlot r
        , rTipSlot = BI.rTipSlot r
        , rUpstream = BI.rUpstream r
        , rUpdatedAt = BI.rUpdatedAt r
        }
