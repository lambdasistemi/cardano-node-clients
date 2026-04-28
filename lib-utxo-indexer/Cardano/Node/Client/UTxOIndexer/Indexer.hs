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
-}
module Cardano.Node.Client.UTxOIndexer.Indexer (
    -- * Indexer handle
    IndexerHandle (..),
    withInMemoryIndexer,
    withRocksDBIndexer,

    -- * Operations
    UtxoOp (..),

    -- * Replay conflict
    ApplyConflict (..),

    -- * Await observations
    AwaitObservation (..),
) where

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
    SlotNo,
    TxIn (..),
    TxOut,
 )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types (
    RollbackPoint (..),
 )
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.List.SampleFibonacci (sampleAtFibonacciIntervals)
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
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Dependent.Map (DMap)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    firstEntry,
    lastEntry,
    nextEntry,
    prevEntry,
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
    iterating RollbackCol $
        firstEntry >>= go 0
  where
    go !n Nothing = pure n
    go !n (Just _) = nextEntry >>= go (n + 1)

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
                    Applied ->
                        atomically $ do
                            modifyTVar' countVar (+ 1)
                            fireWaiters
                                waitersVar
                                observedVar
                                slot
                                bh
                                ops
                    AlreadyApplied -> pure ()
                    Conflict existing _attempted ->
                        throwIO
                            ApplyConflict
                                { acSlot = slot
                                , acExistingBlockHash = existing
                                , acAttemptedBlockHash = bh
                                }
            , rollbackTo = \slot -> do
                deleted <- runTransaction (rollbackToSlot slot)
                atomically $ do
                    modifyTVar' countVar (subtract deleted)
                    pruneObservedAfter observedVar slot
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
            }

{- | Internal: outcome of the apply transaction. Private
to this module — the public API surfaces 'Applied' /
'AlreadyApplied' as an @IO ()@ (with conflict throwing
'ApplyConflict').
-}
data ApplyResult
    = Applied
    | AlreadyApplied
    | Conflict !BlockHash !BlockHash

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
    Transaction IO cf Cols op ApplyResult
applyAndLog slot bh ops = do
    mTipSlot <- Rollbacks.queryTip RollbackCol
    case mTipSlot of
        Nothing -> applyFresh
        Just tipSlot
            | slot > tipSlot -> applyFresh
            | otherwise -> do
                existing <- query RollbackCol slot
                case existing of
                    Nothing ->
                        -- Pruned: we can't compare hashes,
                        -- but the slot is below the tip so
                        -- it has been applied.
                        pure AlreadyApplied
                    Just RollbackPoint{rpMeta = Just existingBh}
                        | existingBh == bh -> pure AlreadyApplied
                        | otherwise ->
                            pure (Conflict existingBh bh)
                    Just RollbackPoint{rpMeta = Nothing} ->
                        -- Indexer always records rpMeta = Just bh;
                        -- a Nothing here is a corruption / schema
                        -- drift signal, not a normal state.
                        error
                            "applyAndLog: RollbackPoint with rpMeta \
                            \= Nothing — schema drift"
  where
    applyFresh = do
        inverses <- traverse step ops
        Rollbacks.storeRollbackPoint
            RollbackCol
            slot
            RollbackPoint
                { rpInverses = reverse inverses
                , rpMeta = Just bh
                }
        pure Applied
    step op = do
        inv <- inverseOf op
        applyOne slot bh op
        pure inv

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

{- | Roll back every slot strictly greater than
@target@. Walks 'RollbackCol' from the highest slot
down via 'lastEntry'/'prevEntry', collecting entries
@> target@, then in a second pass replays each
inverse-op list and deletes the corresponding rollback
entry — both inside the same transaction.

Returns the number of rollback-log entries removed so
the in-memory entry counter stays in sync.
-}
rollbackToSlot ::
    SlotNo ->
    Transaction IO cf Cols op Int
rollbackToSlot target = do
    entries <-
        iterating RollbackCol $
            collectGreaterThan target
    traverse_ undoSlot entries
    pure (length entries)
  where
    -- 'applyOne' on rollback uses the slot+hash of the
    -- rolled-back entry. For an inverse 'UtxoCreate'
    -- (i.e. restoring a previously-spent UTxO) this means
    -- 'ObservationCol' will record the rollback slot as
    -- the observation slot, not the UTxO's original
    -- creation slot. That is a known imprecision: 'awaitTxIn'
    -- after a rollback returns the rollback slot for restored
    -- UTxOs. The TxOut is still correct, which is what
    -- consumers actually care about.
    undoSlot (slot, bh, invs) = do
        traverse_ (applyOne slot bh) invs
        delete RollbackCol slot

{- | Cursor program: from 'lastEntry' walk backwards,
collecting @(slot, blockHash, invs)@ triples while
@slot > target@. Returns them in descending-slot order.
-}
collectGreaterThan ::
    (Monad m) =>
    SlotNo ->
    Cursor
        m
        (KV SlotNo (RollbackPoint UtxoOp BlockHash))
        [(SlotNo, BlockHash, [UtxoOp])]
collectGreaterThan target =
    lastEntry >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = slot, entryValue = rp})
        | slot > target =
            let bh = case rpMeta rp of
                    Just b -> b
                    Nothing ->
                        error
                            "collectGreaterThan: \
                            \RollbackPoint with rpMeta \
                            \= Nothing — schema drift"
                invs = rpInverses rp
             in prevEntry >>= go ((slot, bh, invs) : acc)
        | otherwise = pure (reverse acc)

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
