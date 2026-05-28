{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.Indexer
Description : Address->UTxO indexer state and read API
License     : Apache-2.0

Holds the indexer's in-process state — a 'kv-transactions'
'Database' (in-memory backend in v1) keyed by the 'Cols'
GADT, plus an STM-held map of 'awaitTxIn' waiters — and
exposes the operations the rest of the daemon needs:

* 'applyAtSlot' commits a batch of create/spend operations
  in one transaction, atomically records the inverse list
  in the rollback column, and wakes up any registered
  waiters whose 'TxIn' was just created.
* 'newFollowerState' and 'processFollowerBlock' expose an
  opaque chain-follower 'Runner.processBlock' wrapper for
  restoration/cold-sync phases without leaking the
  database runner type.
* 'rollbackTo' replays the inverse-op log for every slot
  strictly greater than the target. Awaiters whose
  observed 'TxIn' gets rolled back stay closed (the
  observation has already been reported); awaiters still
  pending stay pending.
* 'pruneRollbacks' caps the rollback log at the most
  recent @maxKeep@ entries — the oldest are dropped. This
  is the count-based finality cull (Cardano's @k@-deep
  rule applies per /block/, not per slot, so a count-based
  bound is what consumers actually want).
* 'snapshotAt' prefix-scans every UTxO at a given address
  using a 'Cursor'.
* 'awaitTxIn' blocks until a given 'TxIn' is observed in
  the index (or the optional timeout fires).
* 'liveUtxoHandler' exposes the UTxO storage mutation as a
  generic 'IndexerHandler' for the @block-indexer@
  sublibrary. The generic package still knows nothing about
  'Cols', 'InterestSet', or 'UtxoOp'; those remain UTxO
  indexer concepts.

A 'TVar' tracks the current rollback-log entry count so
the prune step does not re-scan the column on every
block. The counter is in-process state, but it is seeded
from a one-shot scan of 'RollbackCol' on startup so it
stays in sync with whatever the on-disk RocksDB store
contains across restarts.

Two backends are wired in: 'withInMemoryIndexer' for
tests / ephemeral runs and 'withRocksDBIndexer' for the
durable on-disk store. They share all of the apply /
rollback / prune / snapshot / await machinery —
'kv-transactions' makes the choice a one-line backend
swap.

= Compatibility note

'InterestSet' and 'filterBlockOps' are defined here because
handler-level filtering now belongs to 'liveUtxoHandler'. They
remain re-exported by "Cardano.Node.Client.UTxOIndexer.Follower"
so existing consumers can keep their old imports.
-}
module Cardano.Node.Client.UTxOIndexer.Indexer (
    -- * Indexer handle
    IndexerHandle (..),
    IndexerFollowerState,
    withFollowerHandlers,
    withFollowerInterest,
    withInMemoryIndexer,
    withRocksDBIndexer,

    -- * UTxO operations and filters
    InterestSet (..),
    UtxoOp (..),
    filterBlockOps,

    -- * Generic block-indexer handler
    liveUtxoHandler,

    -- * Replay conflict
    ApplyConflict (..),

    -- * Await observations
    AwaitObservation (..),
) where

import Cardano.Node.Client.BlockIndexer.Engine qualified as Engine
import Cardano.Node.Client.BlockIndexer.Handler (
    HandlerBlock (..),
    HandlerContext (..),
    IndexerHandler (..),
 )
import Cardano.Node.Client.BlockIndexer.Handler qualified as Handler
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut,
 )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types (
    RollbackPoint (..),
 )
import ChainFollower.Runner qualified as Runner
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.STM (
    STM,
    TMVar,
    TVar,
    atomically,
    modifyTVar',
    newEmptyTMVar,
    newTVarIO,
    putTMVar,
    readTMVar,
    readTVar,
    readTVarIO,
    writeTVar,
 )
import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Dependent.Map (DMap)
import Data.Foldable (traverse_)
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.SampleFibonacci (sampleAtFibonacciIntervals)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Typeable (Typeable, cast)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    nextEntry,
    seekKey,
 )
import Database.KV.Database (Codecs, KV, mkColumns)
import Database.KV.InMemory (mkInMemoryDatabase)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    DSum ((:=>)),
    RunTransaction (..),
    Transaction,
    delete,
    fromList,
    insert,
    iterating,
    newRunTransaction,
    query,
 )
import Database.RocksDB (
    Config (..),
    columnFamilies,
    withDBCF,
 )

{- | Thrown by 'applyAtSlot' when 'RollbackCol' already
has an entry at the requested slot whose 'BlockHash'
differs from the one the caller is trying to apply.

This means the daemon is being driven with a chain that
diverges from the one already persisted on disk. State
is left untouched; resolving the conflict by finding an
older intersection or rebuilding from Origin is the
recoverability story (#86), not the storage-only #85.

A same-slot, /same/-hash apply is the silent replay
guard: it returns @()@ without updating any state.
-}
data ApplyConflict = ApplyConflict
    { acSlot :: !SlotNo
    , acExistingBlockHash :: !BlockHash
    , acAttemptedBlockHash :: !BlockHash
    }
    deriving stock (Eq, Show)

instance Exception ApplyConflict

{- | An observed @TxIn@ apparition: the slot and block
hash the daemon was at when it processed the
creating block, plus the @TxOut@ inserted.
-}
data AwaitObservation = AwaitObservation
    { aoSlot :: !SlotNo
    , aoBlockHash :: !BlockHash
    , aoTxOut :: !TxOut
    }
    deriving stock (Eq, Show)

type IndexerTx cf op =
    Engine.EngineTx IO cf Cols op

type IndexerBlock = HandlerBlock SlotNo BlockHash [UtxoOp]

{- | Address filter applied to each @[UtxoOp]@ batch before
the live UTxO handler mutates storage.

'IndexAll' preserves every create/spend. 'IndexAddressSet'
keeps creates for the configured addresses and always keeps
spends, so spending a previously-filtered create remains a
clean no-op.

This type remains re-exported from
"Cardano.Node.Client.UTxOIndexer.Follower" for source
compatibility with callers that configured the chain-sync follower
before the handler split.
-}
data InterestSet
    = IndexAll
    | IndexAddressSet !(Set Address)
    deriving stock (Eq, Show)

{- | Pure interest-set filtering for a batch of UTxO operations.

Exported for tests and embedders that want to inspect the same
filtering rule the live handler uses. Existing callers may continue
to import it from "Cardano.Node.Client.UTxOIndexer.Follower".
-}
filterBlockOps :: InterestSet -> [UtxoOp] -> [UtxoOp]
filterBlockOps IndexAll = id
filterBlockOps (IndexAddressSet s) = filter (inInterestSet s)
  where
    inInterestSet set op = case op of
        UtxoCreate _ addr _ -> addr `Set.member` set
        UtxoSpend _ -> True

{- | Opaque chain-follower phase state for the UTxO
indexer. It packages the concrete @kv-transactions@
runner type with the current 'Runner.Phase' so
'withChainSyncFollower' can thread phase state through
roll-forward continuations without exposing backend
internals to downstream consumers.
-}
data IndexerFollowerState where
    IndexerFollowerState ::
        { ifsEngine ::
            !( Engine.EngineState
                cf
                Cols
                op
                IndexerBlock
                [UtxoOp]
                BlockHash
             )
        , ifsInterestSet :: !InterestSet
        , ifsWaiters :: !Waiters
        , ifsObserved :: !Observed
        } ->
        IndexerFollowerState

{- | Operations the rest of the daemon performs against
the indexer state.
-}
data IndexerHandle = IndexerHandle
    { applyAtSlot ::
        SlotNo ->
        BlockHash ->
        [UtxoOp] ->
        IO ()
    -- ^ Atomically apply a batch of create/spend
    -- operations and store the inverse list under the
    -- given slot in 'RollbackCol'. After the
    -- transaction commits, fire any 'awaitTxIn'
    -- waiters whose 'TxIn' was just created.
    --
    -- Replay-aware: if 'RollbackCol' already has an
    -- entry at @slot@ with the /same/ 'BlockHash' the
    -- call is a silent no-op — state, counter, and
    -- waiters are all left untouched. With a /different/
    -- 'BlockHash' an 'ApplyConflict' is thrown;
    -- 'applyAtSlot' never silently overwrites a
    -- previously-applied row.
    , rollbackTo :: SlotNo -> IO ()
    -- ^ Roll the index back to the given slot by
    -- replaying inverse-op lists for every slot
    -- @> target@, in descending slot order.
    , newFollowerState :: Bool -> IO IndexerFollowerState
    -- ^ Build an opaque chain-follower phase state for
    -- 'processFollowerBlock'. Pass 'True' to start in
    -- restoration mode when the rollback log contains no
    -- following rows; pass 'False' for always-following
    -- behavior.
    , processFollowerBlock ::
        IndexerFollowerState ->
        Int ->
        Bool ->
        SlotNo ->
        BlockHash ->
        [UtxoOp] ->
        IO (IndexerFollowerState, Bool)
    -- ^ Process one non-EBB block through
    -- 'ChainFollower.Runner.processBlock'. The 'Bool'
    -- argument is the Runner's within-stability-window
    -- signal: 'False' keeps restoration active, 'True'
    -- transitions to or stays in following. The returned
    -- 'Bool' is 'True' when the block was processed.
    , rollbackFollowerState ::
        IndexerFollowerState ->
        SlotNo ->
        IO IndexerFollowerState
    -- ^ Roll back the persistent indexer and update the
    -- opaque chain-follower phase count.
    , pruneRollbacks :: Int -> IO Int
    -- ^ Keep at most @maxKeep@ rollback-log entries
    -- (the most-recent ones); drop the oldest. Returns
    -- the number of entries deleted. Idempotent.
    --
    -- Implements the count-based finality cull: a block
    -- is final once @k@ later blocks have been applied,
    -- so the inverse-op list keyed at any of the
    -- now-irrelevant earlier blocks is dead weight.
    , snapshotAt :: Address -> IO [(TxIn, TxOut)]
    -- ^ Snapshot every UTxO currently at the given
    -- address, in ascending @TxIn@ order.
    , awaitTxIn :: TxIn -> Maybe Int -> IO (Maybe AwaitObservation)
    -- ^ Block until @txIn@ is observed in the index,
    -- or until the timeout (seconds) fires. Returns
    -- 'Just' with the observation, or 'Nothing' on
    -- timeout. If @txIn@ is already in the index when
    -- called, returns immediately with the
    -- last-observed observation.
    , getResumePoints :: IO [(SlotNo, BlockHash)]
    -- ^ Read 'RollbackCol' newest-to-oldest, thin the
    -- result at Fibonacci intervals (via
    -- 'Cardano.Node.Client.SampleList.sampleList'), and
    -- return the resulting chain-sync resume candidates.
    -- Returns @[]@ when the column is empty (cold boot —
    -- caller should treat that as "resume from Origin").
    --
    -- Newest-first matters because chain-sync picks the
    -- first candidate on the node's current chain. If an
    -- offline rollback dropped our latest saved point
    -- from the node's chain, the next-older retained
    -- point is the correct resume target. Fibonacci
    -- thinning keeps the candidate list log-sized in
    -- @k@ instead of linear: dense near the tip, sparse
    -- deep in the past.
    , getRollbackHistory ::
        IO [(SlotNo, RollbackPoint [UtxoOp] BlockHash)]
    -- ^ Read the raw rollback-log history oldest-to-newest.
    -- Restoration-phase sentinel rows have
    -- @rpInverses = []@ and @rpMeta = Nothing@; following
    -- rows carry one inverse-operation batch and block hash
    -- metadata. Primarily intended for diagnostics and
    -- focused tests.
    }

{- | Open an in-memory indexer, run the action with the
handle, and clean up on exit.

A fresh in-memory database starts empty, but we still
seed the rollback-log counter via 'countRollbackEntries'
to keep this constructor's wiring identical to the
RocksDB one.
-}
withInMemoryIndexer :: (IndexerHandle -> IO a) -> IO a
withInMemoryIndexer action = do
    db <- mkInMemoryDatabase (mkColumns [0 :: Int ..] indexerCodecs)
    runner <- newRunTransaction db
    bootHandle runner action

{- | Open a RocksDB-backed indexer at @path@ (creating
the directory tree if missing) and run the action with
the handle. The on-disk store survives process restart;
on reopen, the rollback-log entry counter is re-derived
by a one-shot scan of 'RollbackCol'.

Three column families are created:

* @utxo-indexer.txin@        — the @TxInCol@ table
* @utxo-indexer.address@     — the @AddressIndex@ table
* @utxo-indexer.rollback@    — the @RollbackCol@ log

The order matters: 'mkColumns' threads the
@'columnFamilies' db@ list through the typed-column
@DMap@ in the same lex order the GADT iterates, so
the names are paired with the right typed selector.
-}
withRocksDBIndexer ::
    FilePath -> (IndexerHandle -> IO a) -> IO a
withRocksDBIndexer path action =
    withDBCF
        path
        def{createIfMissing = True}
        [ ("utxo-indexer.txin", def)
        , ("utxo-indexer.address", def)
        , ("utxo-indexer.observation", def)
        , ("utxo-indexer.rollback", def)
        ]
        $ \rdb -> do
            let database =
                    mkRocksDBDatabase
                        rdb
                        (mkColumns (columnFamilies rdb) indexerCodecs)
            runner <- newRunTransaction database
            bootHandle runner action

{- | Final stage shared by both constructors: derive the
initial rollback-log counter from the database, set up
the await-state TVars, and hand the constructed handle
to the caller's action.
-}
bootHandle ::
    RunTransaction IO cf Cols op ->
    (IndexerHandle -> IO a) ->
    IO a
bootHandle runner@RunTransaction{runTransaction} action = do
    initialCount <- runTransaction countRollbackEntries
    waitersVar <- newTVarIO Map.empty
    observedVar <- newTVarIO Map.empty
    countVar <- newTVarIO initialCount
    action (mkHandle runner waitersVar observedVar countVar)

-- | Shared codec definitions for the indexer columns.
indexerCodecs :: DMap Cols Codecs
indexerCodecs =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        ]

{- | One-shot scan of 'RollbackCol' returning the entry
count. O(n) in the column size — called once at startup
and never again; the in-memory counter handles steady
state.
-}
countRollbackEntries ::
    Transaction IO cf Cols op Int
countRollbackEntries =
    Engine.countRollbackEntries RollbackCol

-- Internal -------------------------------------------------------

{- | Map from a TxIn awaited by some caller to the
list of empty TMVars waiting on it. Each TMVar gets
'putTMVar'd with the observation when the TxIn is
created.
-}
type Waiters = TVar (Map TxIn [TMVar AwaitObservation])

{- | Map from observed TxIns to their last observation.
Lets 'awaitTxIn' return immediately when called for a
TxIn that was already created; entries are pruned on
spend / rollback.
-}
type Observed = TVar (Map TxIn AwaitObservation)

mkHandle ::
    forall cf op.
    RunTransaction IO cf Cols op ->
    Waiters ->
    Observed ->
    TVar Int ->
    IndexerHandle
mkHandle
    RunTransaction{runTransaction}
    waitersVar
    observedVar
    countVar =
        IndexerHandle
            { applyAtSlot = \slot bh ops -> do
                outcome <- runTransaction (applyAndLog slot bh ops)
                case outcome of
                    Engine.ApplyLogApplied ->
                        atomically $ do
                            modifyTVar' countVar (+ 1)
                            fireWaiters
                                waitersVar
                                observedVar
                                slot
                                bh
                                ops
                    Engine.ApplyLogAlreadyApplied -> pure ()
                    Engine.ApplyLogConflict existing _attempted ->
                        throwIO
                            ApplyConflict
                                { acSlot = slot
                                , acExistingBlockHash = existing
                                , acAttemptedBlockHash = bh
                                }
            , rollbackTo = \slot -> do
                deleted <-
                    runTransaction $
                        Engine.rollbackLogAfter
                            RollbackCol
                            applyRollbackEntry
                            slot
                atomically $ do
                    modifyTVar' countVar (subtract deleted)
                    pruneObservedAfter observedVar slot
            , newFollowerState =
                newIndexerFollowerState
                    runTransaction
                    waitersVar
                    observedVar
                    countVar
                    IndexAll
            , processFollowerBlock =
                processIndexerFollowerBlock
            , rollbackFollowerState =
                rollbackIndexerFollowerState
            , pruneRollbacks = \maxKeep -> do
                count <- readTVarIO countVar
                deleted <-
                    runTransaction $
                        Rollbacks.pruneExcess
                            RollbackCol
                            count
                            maxKeep
                atomically $
                    modifyTVar' countVar (subtract deleted)
                pure deleted
            , snapshotAt =
                runTransaction . iterating AddressIndex . scanAddress
            , awaitTxIn =
                doAwait runTransaction waitersVar observedVar
            , getResumePoints = do
                history <-
                    runTransaction
                        (Rollbacks.queryHistory RollbackCol)
                let pairs =
                        reverse
                            [ (slot, bh)
                            | (slot, RollbackPoint{rpMeta = Just bh}) <-
                                history
                            ]
                ref <- newIORef pairs
                sampleAtFibonacciIntervals (popFront ref)
            , getRollbackHistory =
                runTransaction
                    (Rollbacks.queryHistory RollbackCol)
            }

{- | Retarget an opaque follower state to a handler list.

This is the handler-list seam used by
"Cardano.Node.Client.UTxOIndexer.Follower". The public
'newFollowerState' handle field keeps its historical
@Bool -> IO IndexerFollowerState@ shape and defaults to 'IndexAll';
the follower applies this helper internally when
'ChainSyncConfig.csHandlers' supplies a richer handler pipeline.
-}
withFollowerHandlers ::
    InterestSet ->
    NonEmpty (IndexerHandler Cols [UtxoOp]) ->
    IndexerFollowerState ->
    IndexerFollowerState
withFollowerHandlers
    interestSet
    handlers
    IndexerFollowerState
        { ifsEngine = engine
        , ifsWaiters = waitersVar
        , ifsObserved = observedVar
        } =
        IndexerFollowerState
            { ifsEngine =
                remapEngineHandlers
                    handlers
                    engine
            , ifsInterestSet = interestSet
            , ifsWaiters = waitersVar
            , ifsObserved = observedVar
            }

{- | Retarget an opaque follower state to a handler interest set.

Compatibility wrapper for existing callers. It preserves the historical
single live UTxO handler behavior while sharing the same retargeting path
as 'withFollowerHandlers'.
-}
withFollowerInterest ::
    InterestSet ->
    IndexerFollowerState ->
    IndexerFollowerState
withFollowerInterest interestSet =
    withFollowerHandlers interestSet (liveUtxoHandler interestSet :| [])

remapEngineHandlers ::
    NonEmpty (IndexerHandler Cols [UtxoOp]) ->
    Engine.EngineState
        cf
        Cols
        op
        IndexerBlock
        [UtxoOp]
        BlockHash ->
    Engine.EngineState
        cf
        Cols
        op
        IndexerBlock
        [UtxoOp]
        BlockHash
remapEngineHandlers handlers engine =
    engine
        { Engine.enginePhase =
            remapPhaseHandlers
                handlers
                (Engine.enginePhase engine)
        }

remapPhaseHandlers ::
    NonEmpty (IndexerHandler Cols [UtxoOp]) ->
    Engine.EnginePhase cf Cols op IndexerBlock [UtxoOp] BlockHash ->
    Engine.EnginePhase cf Cols op IndexerBlock [UtxoOp] BlockHash
remapPhaseHandlers handlers = \case
    Runner.InRestoration _ ->
        Runner.InRestoration
            (Handler.composeHandlerRestoring handlers)
    Runner.InFollowing count _ ->
        Runner.InFollowing
            count
            (Handler.composeHandlerFollowing handlers)

newIndexerFollowerState ::
    (forall a. IndexerTx cf op a -> IO a) ->
    Waiters ->
    Observed ->
    TVar Int ->
    InterestSet ->
    Bool ->
    IO IndexerFollowerState
newIndexerFollowerState
    runTransaction
    waitersVar
    observedVar
    countVar
    interestSet
    startRestoring = do
        history <- runTransaction (Rollbacks.queryHistory RollbackCol)
        count <- readTVarIO countVar
        let hasFollowingRows =
                any (isJust . rpMeta . snd) history
            handlers = liveUtxoHandler interestSet :| []
            restoring = Handler.composeHandlerRestoring handlers
            phase
                | startRestoring && not hasFollowingRows =
                    Runner.InRestoration restoring
                | otherwise =
                    Runner.InFollowing
                        count
                        (Handler.composeHandlerFollowing handlers)
        pure
            IndexerFollowerState
                { ifsEngine =
                    Engine.EngineState
                        { Engine.engineRunTransaction =
                            runTransaction
                        , Engine.engineCount = countVar
                        , Engine.enginePhase = phase
                        }
                , ifsInterestSet = interestSet
                , ifsWaiters = waitersVar
                , ifsObserved = observedVar
                }

processIndexerFollowerBlock ::
    IndexerFollowerState ->
    Int ->
    Bool ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    IO (IndexerFollowerState, Bool)
processIndexerFollowerBlock
    IndexerFollowerState
        { ifsEngine = engine
        , ifsInterestSet = interestSet
        , ifsWaiters = waitersVar
        , ifsObserved = observedVar
        }
    securityParam
    withinStabilityWindow
    slot
    bh
    ops = do
        let phase = Engine.enginePhase engine
        engine' <-
            Engine.processEngineBlock
                RollbackCol
                securityParam
                withinStabilityWindow
                slot
                HandlerBlock
                    { hbSlot = slot
                    , hbMeta = bh
                    , hbPayload = ops
                    }
                engine
        let appliedOps = filterBlockOps interestSet ops
        when (Engine.blockWasFollowed phase withinStabilityWindow) $
            atomically $
                fireWaiters
                    waitersVar
                    observedVar
                    slot
                    bh
                    appliedOps
        pure
            ( IndexerFollowerState
                { ifsEngine = engine'
                , ifsInterestSet = interestSet
                , ifsWaiters = waitersVar
                , ifsObserved = observedVar
                }
            , True
            )

rollbackIndexerFollowerState ::
    IndexerFollowerState ->
    SlotNo ->
    IO IndexerFollowerState
rollbackIndexerFollowerState
    IndexerFollowerState
        { ifsEngine = engine
        , ifsInterestSet = interestSet
        , ifsWaiters = waitersVar
        , ifsObserved = observedVar
        }
    slot = do
        (engine', _deleted) <-
            Engine.rollbackEngineState
                RollbackCol
                applyRollbackEntry
                slot
                engine
        atomically $
            pruneObservedAfter observedVar slot
        pure
            IndexerFollowerState
                { ifsEngine = engine'
                , ifsInterestSet = interestSet
                , ifsWaiters = waitersVar
                , ifsObserved = observedVar
                }

applyOpsOnly ::
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    Transaction IO cf Cols op ()
applyOpsOnly slot bh =
    traverse_ (applyOne slot bh)

{- | Live UTxO storage handler for the generic block-indexer engine.

The handler owns UTxO-specific mutation: interest-set filtering,
inverse creation, applying creates/spends, and applying stored
rollback inverses. The generic block-indexer engine owns only the
rollback-log transaction boundary and phase bookkeeping.
-}
liveUtxoHandler :: InterestSet -> IndexerHandler Cols [UtxoOp]
liveUtxoHandler interestSet =
    IndexerHandler
        { handlerRestore = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
            applyOpsOnly slot bh (filterBlockOps interestSet ops)
        , handlerFollow = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
            reverse
                <$> traverse
                    (followOne slot bh)
                    (filterBlockOps interestSet ops)
        , handlerRollback = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
            applyOpsOnly slot bh ops
        }
  where
    followOne slot bh op = do
        inv <- inverseOf op
        applyOpsOnly slot bh [op]
        pure inv

utxoContextSlotHash ::
    (Typeable slot, Typeable meta) =>
    HandlerContext slot meta ->
    (SlotNo, BlockHash)
utxoContextSlotHash HandlerContext{hcSlot, hcMeta} =
    case (cast hcSlot, hcMeta >>= cast) of
        (Just slot, Just bh) -> (slot, bh)
        _ -> (SlotNo 0, BlockHash mempty)

{- | Within one transaction: decide whether @slot@ has
already been applied.

The watermark is 'RollbackCol''s @lastEntry@ — the most
recent applied @(slot, blockHash)@ pair. We rely on
this rather than @query RollbackCol slot@ alone because
finality pruning ('pruneRollbacks') drops the rollback
rows of older finalized slots; their @(slot,
blockHash)@ pair is gone from the column even though
the slot is firmly applied.

Decision tree:

* @slot > tipSlot@ (or column empty) — fresh apply.
  Compute inverses, apply each op, store the reversed
  inverse list under @slot@, return 'Applied'.
* @slot ≤ tipSlot@ — the slot is in the past. We have
  two cases:
    * 'RollbackCol' still has a row for @slot@: compare
      hashes (same → 'AlreadyApplied', differs →
      'Conflict').
    * Pruned out — return 'AlreadyApplied'. We cannot
      detect a hash conflict at a slot whose history
      we no longer have, but we know the slot was
      applied (by virtue of being below the tip), so
      replay-from-Origin must skip it. Detecting fork
      conflicts past the security parameter is out of
      scope here (it would require keeping every
      historical @(slot, hash)@ forever).

Without this watermark check the previous implementation
had a soft-corruption bug: replay-from-Origin against a
populated, partially-pruned DB would re-apply early
slots whose rollback row had been pruned but skip later
slots whose row survived, resurrecting any UTxO that was
created early and later spent.

Computing the inverse before applying is essential —
@query@ inside the same transaction sees buffered
writes (read-your-writes), so once an op is applied,
its inverse cannot be recovered from a later @query@.
-}
applyAndLog ::
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    Transaction IO cf Cols op (Engine.ApplyLogResult BlockHash)
applyAndLog slot bh ops =
    Engine.applyWithRollbackLog
        RollbackCol
        slot
        bh
        applyFresh
  where
    applyFresh =
        Handler.followHandlers
            (liveUtxoHandler IndexAll :| [])
            HandlerContext
                { hcSlot = slot
                , hcMeta = Just bh
                }
            ops

{- | After @applyAndLog@ commits, walk the ops and:

* For each @UtxoCreate txIn _addr txOut@: build an
  observation and store it in the 'Observed' map; pop
  any waiters from the 'Waiters' map and signal each
  via @putTMVar@.
* For each @UtxoSpend txIn@: remove @txIn@ from the
  'Observed' map (a subsequent re-creation of the same
  TxIn after rollback will repopulate it).

All in one STM transaction so the maps stay consistent.
-}
fireWaiters ::
    Waiters ->
    Observed ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    STM ()
fireWaiters waitersVar observedVar slot bh = traverse_ go
  where
    go (UtxoCreate txIn _addr txOut) = do
        let obs =
                AwaitObservation
                    { aoSlot = slot
                    , aoBlockHash = bh
                    , aoTxOut = txOut
                    }
        modifyTVar' observedVar (Map.insert txIn obs)
        waiters <- readTVar waitersVar
        case Map.lookup txIn waiters of
            Nothing -> pure ()
            Just ws -> do
                writeTVar waitersVar (Map.delete txIn waiters)
                traverse_ (`putTMVar` obs) ws
    go (UtxoSpend txIn) =
        modifyTVar' observedVar (Map.delete txIn)

{- | After a rollback, drop observations whose slot is
@> target@. Observations at-or-below the target stay
(they reflect state that survived).
-}
pruneObservedAfter :: Observed -> SlotNo -> STM ()
pruneObservedAfter observedVar target =
    modifyTVar'
        observedVar
        (Map.filter (\obs -> aoSlot obs <= target))

{- | 'awaitTxIn' has three answer paths:

1. The in-process 'Observed' map remembers TxIns
   created in this run; a hit returns immediately.
2. A miss in the in-process map reads the persistent
   'ObservationCol' so a UTxO created in a /previous/
   run is still answerable in O(1) without scanning.
   To return the full @AwaitObservation@ shape we also
   read 'AddressIndex' for the @TxOut@ (via 'TxInCol'
   for the address).
3. A miss in both falls back to the slow path: register
   a TMVar waiter and either block or time out.
-}
doAwait ::
    (forall a. Transaction IO cf Cols op a -> IO a) ->
    Waiters ->
    Observed ->
    TxIn ->
    Maybe Int ->
    IO (Maybe AwaitObservation)
doAwait runTx waitersVar observedVar txIn mTimeout = do
    observed <- readTVarIO observedVar
    case Map.lookup txIn observed of
        Just obs -> pure (Just obs)
        Nothing -> do
            mObs <- runTx (lookupObservation txIn)
            case mObs of
                Just obs -> pure (Just obs)
                Nothing -> blockOnWaiter
  where
    blockOnWaiter = do
        tmv <- atomically $ do
            t <- newEmptyTMVar
            modifyTVar'
                waitersVar
                (Map.alter (insertWaiter t) txIn)
            pure t
        case mTimeout of
            Nothing -> Just <$> atomically (readTMVar tmv)
            Just secs ->
                either Just (\() -> Nothing)
                    <$> race
                        (atomically (readTMVar tmv))
                        (threadDelay (secs * 1_000_000))
    insertWaiter t Nothing = Just [t]
    insertWaiter t (Just xs) = Just (t : xs)

{- | Persistent fast-path for 'awaitTxIn': join
'ObservationCol' with 'TxInCol' + 'AddressIndex' to
reconstruct an 'AwaitObservation' for a 'TxIn' created
in some prior session. Returns 'Nothing' if the 'TxIn'
is not observed (either never created or already spent).
-}
lookupObservation ::
    TxIn ->
    Transaction IO cf Cols op (Maybe AwaitObservation)
lookupObservation txIn = do
    mObs <- query ObservationCol txIn
    case mObs of
        Nothing -> pure Nothing
        Just (slot, bh) -> do
            mAddr <- query TxInCol txIn
            case mAddr of
                Nothing -> pure Nothing
                Just addr -> do
                    mOut <- query AddressIndex (AddrKey addr txIn)
                    case mOut of
                        Nothing -> pure Nothing
                        Just txOut ->
                            pure $
                                Just
                                    AwaitObservation
                                        { aoSlot = slot
                                        , aoBlockHash = bh
                                        , aoTxOut = txOut
                                        }

{- | Apply a rollback-log entry collected by the generic
engine rollback walk.

'applyOne' on rollback uses the slot+hash of the
rolled-back entry. For an inverse 'UtxoCreate' (i.e.
restoring a previously-spent UTxO) this means
'ObservationCol' will record the rollback slot as the
observation slot, not the UTxO's original creation slot.
That is a known imprecision: 'awaitTxIn' after a rollback
returns the rollback slot for restored UTxOs. The TxOut
is still correct, which is what consumers actually care
about.
-}
applyRollbackEntry ::
    SlotNo ->
    Maybe BlockHash ->
    [[UtxoOp]] ->
    Transaction IO cf Cols op ()
applyRollbackEntry slot (Just bh) invBatches =
    traverse_
        ( Handler.rollbackHandlers
            (liveUtxoHandler IndexAll :| [])
            HandlerContext
                { hcSlot = slot
                , hcMeta = Just bh
                }
        )
        invBatches
applyRollbackEntry _slot Nothing [] =
    pure ()
applyRollbackEntry _slot Nothing (_ : _) =
    error
        "applyRollbackEntry: sentinel RollbackPoint carries \
        \inverse operations — schema drift"

-- | Inverse of a single op against current state.
inverseOf ::
    UtxoOp ->
    Transaction IO cf Cols op UtxoOp
inverseOf op = do
    let txIn = opTxIn op
    mAddr <- query TxInCol txIn
    case mAddr of
        Nothing -> pure (UtxoSpend txIn)
        Just addr -> do
            mTxOut <- query AddressIndex (AddrKey addr txIn)
            case mTxOut of
                Just txOut -> pure (UtxoCreate txIn addr txOut)
                Nothing -> pure (UtxoSpend txIn)

opTxIn :: UtxoOp -> TxIn
opTxIn (UtxoCreate t _ _) = t
opTxIn (UtxoSpend t) = t

{- | Apply one op against the column state. The
@(slot, bh)@ pair is recorded into 'ObservationCol' on
'UtxoCreate' so 'awaitTxIn' can answer the
"already observed?" fast-path question across process
restart; on 'UtxoSpend' the corresponding observation is
removed.
-}
applyOne ::
    SlotNo ->
    BlockHash ->
    UtxoOp ->
    Transaction IO cf Cols op ()
applyOne slot bh (UtxoCreate txIn addr txOut) = do
    insert TxInCol txIn addr
    insert AddressIndex (AddrKey addr txIn) txOut
    insert ObservationCol txIn (slot, bh)
applyOne _slot _bh (UtxoSpend txIn) = do
    mAddr <- query TxInCol txIn
    case mAddr of
        Nothing -> pure ()
        Just addr -> do
            delete AddressIndex (AddrKey addr txIn)
            delete TxInCol txIn
            delete ObservationCol txIn

{- | Cursor program: seek to the synthetic minimum key
under @addr@ and walk forward, collecting every entry
whose key still lives under @addr@.
-}
scanAddress ::
    (Monad m) =>
    Address ->
    Cursor m (KV AddrKey TxOut) [(TxIn, TxOut)]
scanAddress addr =
    let seekTo =
            AddrKey
                addr
                (TxIn (BS.replicate 32 0) 0)
     in seekKey seekTo >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = k, entryValue = v})
        | addrKeyAddress k == addr =
            nextEntry >>= go ((addrKeyTxIn k, v) : acc)
        | otherwise = pure (reverse acc)

{- | Stream a mutable list reference one element at a
time, returning 'Nothing' when exhausted. Used to feed
'sampleAtFibonacciIntervals' from a pure list — the
library function expects an @m (Maybe a)@ stream.
-}
popFront :: IORef [a] -> IO (Maybe a)
popFront ref = do
    xs <- readIORef ref
    case xs of
        [] -> pure Nothing
        (y : ys) -> do
            writeIORef ref ys
            pure (Just y)
