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
-}
module Cardano.Node.Client.UTxOIndexer.Follower (
    -- * Configuration
    ChainSyncConfig (..),
    coldBootResumePoints,

    -- * Interest-set filter
    InterestSet (..),
    filterBlockOps,

    -- * Readiness state
    Readiness (..),
    initialReadiness,

    -- * Handle
    FollowerHandle (..),

    -- * Bring-up
    withChainSyncFollower,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
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
import Cardano.Node.Client.UTxOIndexer.BlockExtract (
    extractBlock,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address,
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
import Control.Monad (void)
import Control.Tracer (Tracer, nullTracer)
import Data.ByteString.Short qualified as SBS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64)
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
    }
    deriving stock (Show)

{- | Address filter applied to each @[UtxoOp]@ batch
between 'extractBlock' and 'applyAtSlot'.

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
(the value is captured by reference at apply time but
not exposed for STM updates). A future ticket can lift
the field into an STM-mutable value if multi-tenant
onboarding requires it.
-}
data InterestSet
    = -- | Pass-through; preserves the pre-#158 daemon
      -- semantics.
      IndexAll
    | -- | Keep only 'UtxoCreate' ops whose address
      -- belongs to the set. Spends always pass.
      IndexAddressSet !(Set Address)
    deriving stock (Eq, Show)

{- | Pure: filter a batch of 'UtxoOp's against an
'InterestSet'. Called by the follower's @rollForward@
between 'extractBlock' and 'applyAtSlot'; exported so
unit tests can exercise the filter without spinning up
a chain-sync session.
-}
filterBlockOps :: InterestSet -> [UtxoOp] -> [UtxoOp]
filterBlockOps IndexAll = id
filterBlockOps (IndexAddressSet s) = filter (inInterestSet s)
  where
    inInterestSet :: Set Address -> UtxoOp -> Bool
    inInterestSet set op = case op of
        UtxoCreate _ addr _ -> addr `Set.member` set
        UtxoSpend _ -> True

{- | Live readiness snapshot updated by the follower
thread after every roll-forward and on every reconnect
status transition.

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
withChainSyncFollower tracer cfg idx action = do
    now <- getCurrentTime
    readinessVar <- newTVarIO (initialReadiness now)
    let chainSession = do
            bootMode <- detectBootMode idx
            let resumePoints = case bootMode of
                    ColdBoot -> coldBootResumePoints cfg
                    WarmBoot ps -> fmap toHeaderPoint ps
            runChainSyncN2C
                (EpochSlots (csByronEpochSlots cfg))
                (csNetworkMagic cfg)
                (csRelaySocket cfg)
                ( mkChainSyncN2C
                    nullTracer
                    nullTracer
                    ( mkIntersector
                        bootMode
                        cfg
                        readinessVar
                        idx
                    )
                    resumePoints
                )
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
    withAsync (void chainAction) $ \a ->
        action
            FollowerHandle
                { fhReadiness = readTVar readinessVar
                , fhAsync = a
                }

{- | Initial 'Readiness' value at bring-up: no slots
applied yet, supervisor-reported state is
'UpstreamConnected' (the supervisor will flip it to
'UpstreamDisconnected' on the first failed probe;
matches the bundled daemon's historical initial
@ReadyStatus@).
-}
initialReadiness :: UTCTime -> Readiness
initialReadiness now =
    Readiness
        { rProcessedSlot = Nothing
        , rTipSlot = Nothing
        , rUpstream = UpstreamConnected
        , rUpdatedAt = now
        }

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
                pure (mkFollower cfg readinessVar idx)
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
    Follower HeaderPoint Network.SlotNo Fetched
mkFollower cfg readinessVar idx = self
  where
    self =
        Follower
            { rollForward = \fetched tip -> do
                let (slot, rawOps) =
                        extractBlock (fetchedBlock fetched)
                    ops =
                        filterBlockOps
                            (csInterestSet cfg)
                            rawOps
                    bh =
                        pointToBlockHash
                            (fetchedPoint fetched)
                applyAtSlot idx slot bh ops
                _ <-
                    pruneRollbacks
                        idx
                        (csSecurityParamK cfg)
                updateReadiness readinessVar slot tip
                pure self
            , rollBackward = \point -> do
                let slot = case Network.pointSlot point of
                        Network.Point.Origin -> SlotNo 0
                        Network.Point.At s ->
                            SlotNo (Network.unSlotNo s)
                rollbackTo idx slot
                pure (Progress self)
            }

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
applyUpstreamToReadiness newStatus now r =
    r{rUpstream = newStatus, rUpdatedAt = now}
