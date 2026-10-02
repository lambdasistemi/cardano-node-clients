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
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
    withRocksDBIndexerRunner,
    withRocksDBIndexerWith,
    withRocksDBIndexerRunnerWith,

    -- * Open options
    OpenOptions (..),
    defaultOpenOptions,

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

    -- * Typed asset read
    AssetSnapshot (..),
    AssetMatch (..),
    AssetQueryUnavailable (..),

    -- * Indexed read view
    ReadQuery (..),
    ReadResult (..),
    IndexedView (..),

    -- * Build coverage
    BuildCoverage (..),
    StoreCoverage (..),
    BuildCoverageRefusal (..),
    encodeBuildCoverage,
    decodeBuildCoverage,
) where

import Cardano.Node.Client.BlockIndexer.Engine qualified as Engine
import Cardano.Node.Client.BlockIndexer.Handler (
    HandlerBlock (..),
    HandlerContext (..),
    IndexerHandler (..),
 )
import Cardano.Node.Client.BlockIndexer.Handler qualified as Handler
import Cardano.Node.Client.UTxOIndexer.ColumnFamilies (createColumnFamilies)
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    assetIndexCodecs,
    metaCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.TxOutView (
    TxOutView (..),
    decodeTxOutView,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    AssetKey (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut,
    assetKeyFromBytes,
    assetKeyToBytes,
    txInFromBytes,
    txInToBytes,
 )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types (
    RollbackPoint (..),
 )
import ChainFollower.Runner qualified as Runner
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, race, withAsync)
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
import Control.Exception (Exception, IOException, throwIO, try)
import Control.Monad (guard, when)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Dependent.Map (DMap)
import Data.Dependent.Map qualified as DMap
import Data.Foldable (traverse_)
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.SampleFibonacci (sampleAtFibonacciIntervals)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Typeable (Typeable, cast)
import Data.Word (Word64)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    firstEntry,
    lastEntry,
    nextEntry,
    prevEntry,
    seekKey,
 )
import Database.KV.Database (Codecs, Column (..), Database (..), KV, QueryIterator (..), mkColumns)
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
    BatchOp,
    ColumnFamily,
    Config (..),
    DB,
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

{- | One live holder of a queried asset, read in the same storage
transaction as the snapshot's point.
-}
data AssetMatch = AssetMatch
    { amTxIn :: !TxIn
    -- ^ The holding output's reference.
    , amTxOut :: !TxOut
    -- ^ The stored output bytes, byte-identical to what
    -- 'snapshotAt' returns for this 'TxIn'.
    , amQuantity :: !Word64
    -- ^ The quantity of the asset in that output.
    , amCreatedSlot :: !SlotNo
    -- ^ The slot of the block that created the output.
    , amCreatedBlockHash :: !BlockHash
    -- ^ The hash of the block that created the output.
    }
    deriving stock (Eq, Show)

{- | A consistent read of every live holder of one asset, taken in
a single storage transaction.
-}
data AssetSnapshot = AssetSnapshot
    { asPoint :: !(SlotNo, BlockHash)
    -- ^ The indexed point (newest applied block) the matches were
    -- read at.
    , asMatches :: [AssetMatch]
    -- ^ Every live holder, in ascending 'TxIn' order.
    }
    deriving stock (Eq, Show)

{- | Why an asset query cannot be answered. Stores without a
complete asset index, or without an indexed point, answer with an
explicit unavailability — never an empty or partial match list.
-}
data AssetQueryUnavailable
    = -- | The store predates the asset index (or lost completeness).
      AssetIndexAbsent
    | -- | The store reflects no applied block with block-hash
      -- metadata (empty, or restoration-only).
      NoIndexedPoint
    | -- | An asset row references a 'TxIn' with missing live data.
      AssetIndexInconsistent !TxIn
    | -- | An upgrade of the asset index is in progress.
      AssetIndexRebuilding
    deriving stock (Eq, Show)

-- | A query in an ordered, nonempty indexed read batch.
data ReadQuery
    = -- | Every live output at an address.
      AddressQuery !Address
    | -- | Every live holder of the policy and asset name.
      AssetQuery !PolicyId !AssetName
    deriving stock (Eq, Show)

-- | One answer corresponding to the query at the same batch position.
data ReadResult
    = -- | Stored outputs in ascending 'TxIn' order.
      AddressResult [(TxIn, TxOut)]
    | -- | Asset holders in ascending 'TxIn' order, retaining creation points.
      AssetResult [AssetMatch]
    deriving stock (Eq, Show)

{- | A materialized batch read from one storage transaction. Traversing
the view never reads storage and remains valid after the store closes.
-}
data IndexedView = IndexedView
    { ivPoint :: !(SlotNo, BlockHash)
    -- ^ The indexed point shared by all answers.
    , ivResults :: !(NonEmpty ReadResult)
    -- ^ One answer per input query, preserving order and duplicates.
    }
    deriving stock (Eq, Show)

{- | The coverage a store is built with: where its history starts
('Nothing' for the chain's origin, or the block it starts from) and
which addresses it indexes. Equality is exact, including the address
set.
-}
data BuildCoverage = BuildCoverage
    { bcStartPoint :: !(Maybe (SlotNo, BlockHash))
    , bcInterestSet :: !InterestSet
    }
    deriving stock (Eq, Show)

{- | What a store knows about its own coverage: the coverage recorded
when it was created, or nothing (a store created before coverage was
recorded, or one without a metadata column).
-}
data StoreCoverage
    = CoverageRecorded !BuildCoverage
    | CoverageUnrecorded
    deriving stock (Eq, Show)

{- | Why a store refuses a session's coverage: it was built with a
different one, or its record does not decode. The store is left
untouched.
-}
data BuildCoverageRefusal
    = BuildCoverageMismatch
        { recorded :: !BuildCoverage
        , requested :: !BuildCoverage
        }
    | BuildCoverageUndecodable
        { raw :: !BS.ByteString
        , requested :: !BuildCoverage
        }
    deriving stock (Eq, Show)

instance Exception BuildCoverageRefusal

{- | The build-coverage record, version 1, integers big-endian: @0x01@;
the start, @0x00@ for the origin or @0x01@, the slot (8 bytes), the
hash length (4 bytes) and the hash; the addresses, @0x00@ for all or
@0x01@, their count (4 bytes) and, in ascending byte order, each
address's length (4 bytes) and bytes.
-}
encodeBuildCoverage :: BuildCoverage -> BS.ByteString
encodeBuildCoverage BuildCoverage{bcStartPoint, bcInterestSet} =
    BS.concat $
        [BS.singleton 1]
            <> case bcStartPoint of
                Nothing -> [BS.singleton 0]
                Just (SlotNo slot, BlockHash hash) ->
                    [BS.singleton 1, bigEndian 8 slot, sized hash]
            <> case bcInterestSet of
                IndexAll -> [BS.singleton 0]
                IndexAddressSet addresses ->
                    [BS.singleton 1, bigEndian 4 (Set.size addresses)]
                        <> map (sized . unAddress) (Set.toAscList addresses)
  where
    sized bytes = bigEndian 4 (BS.length bytes) <> bytes

{- | Decode a build-coverage record. Any other bytes — another version,
a short or overlong value, addresses out of ascending order or repeated
— are 'Nothing'.
-}
decodeBuildCoverage :: BS.ByteString -> Maybe BuildCoverage
decodeBuildCoverage bytes = do
    (version, afterVersion) <- BS.uncons bytes
    guard (version == 1)
    (start, afterStart) <- tagged afterVersion (pure Nothing) startPoint
    (interest, rest) <- tagged afterStart (pure IndexAll) addressSet
    guard (BS.null rest)
    pure BuildCoverage{bcStartPoint = start, bcInterestSet = interest}
  where
    tagged input none some = do
        (tag, rest) <- BS.uncons input
        case tag of
            0 -> (,rest) <$> none
            1 -> some rest
            _ -> Nothing
    startPoint input = do
        (slot, afterSlot) <- fixed 8 input
        (hash, rest) <- sizedField afterSlot
        pure (Just (SlotNo slot, BlockHash hash), rest)
    addressSet input = do
        (count, afterCount) <- fixed 4 input
        (addresses, rest) <- fields (count :: Word64) afterCount
        guard (and (zipWith (<) addresses (drop 1 addresses)))
        pure (IndexAddressSet (Set.fromDistinctAscList (map Address addresses)), rest)
    fields 0 input = Just ([], input)
    fields n input = do
        (field, afterField) <- sizedField input
        (others, rest) <- fields (n - 1) afterField
        pure (field : others, rest)
    sizedField input = do
        (len, afterLen) <- fixed 4 input
        guard (fromIntegral (BS.length afterLen) >= (len :: Word64))
        pure (BS.splitAt (fromIntegral len) afterLen)
    fixed n input = do
        guard (BS.length input >= n)
        let (field, rest) = BS.splitAt n input
        pure (BS.foldl' (\acc b -> acc `shiftL` 8 .|. fromIntegral b) 0 field, rest)

-- | @n@ big-endian bytes of a non-negative integer.
bigEndian :: (Integral a) => Int -> a -> BS.ByteString
bigEndian n x =
    BS.pack
        [ fromIntegral (toInteger x `shiftR` (8 * i))
        | i <- [n - 1, n - 2 .. 0]
        ]

-- | The metadata key holding the build-coverage record.
buildCoverageKey :: BS.ByteString
buildCoverageKey = "build-coverage"

{- | The claim of a session's coverage on a store with metadata
columns: an existing record is served when equal and refused
otherwise, never rewritten; an empty store without a record gains the
session's coverage; a non-empty store without one stays unrecorded.
-}
claimCoverage ::
    BuildCoverage ->
    Transaction IO cf Cols op (Either BuildCoverageRefusal StoreCoverage)
claimCoverage requested = do
    stored <- query MetaCol buildCoverageKey
    case stored of
        Just bytes -> pure $ case decodeBuildCoverage bytes of
            Nothing -> Left BuildCoverageUndecodable{raw = bytes, requested}
            Just recorded
                | recorded == requested -> Right (CoverageRecorded recorded)
                | otherwise -> Left BuildCoverageMismatch{recorded, requested}
        Nothing -> do
            empty <- isEmptyStore
            if empty
                then
                    Right (CoverageRecorded requested)
                        <$ insert MetaCol buildCoverageKey (encodeBuildCoverage requested)
                else pure (Right CoverageUnrecorded)

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
        UtxoRestore _ addr _ _ _ -> addr `Set.member` set
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
        , ifsAssetColumns :: !AssetColumns
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
    , assetUtxos ::
        PolicyId ->
        AssetName ->
        IO (Either AssetQueryUnavailable AssetSnapshot)
    -- ^ Read every live holder of the asset with the stored output
    -- bytes, quantity and true creation point, plus the indexed
    -- point — all from one storage transaction.
    , claimBuildCoverage ::
        BuildCoverage ->
        IO (Either BuildCoverageRefusal StoreCoverage)
    -- ^ Decide, in one transaction, the coverage a session with the
    -- given coverage serves. A store without a record gains it when
    -- empty (no live output, no rollback-log entry) and is
    -- 'CoverageUnrecorded' otherwise; a recorded store serves an equal
    -- coverage and refuses a different one or an undecodable record.
    -- The record is written once and never changed. A store opened
    -- without its metadata column (four families) is
    -- 'CoverageUnrecorded'.
    , readView :: NonEmpty ReadQuery -> IO (Either AssetQueryUnavailable IndexedView)
    -- ^ Read the point, availability and all answers in one transaction.
    -- Refuse the whole batch when the asset index is unavailable, including
    -- address-only batches; 'snapshotAt' remains independently available.
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
    withInMemoryIndexerRunner $ \handle _runner ->
        action handle

{- | Open an in-memory indexer and expose both the public
'IndexerHandle' and the underlying transaction runner.

Most callers should use 'withInMemoryIndexer'. Server-style callers
that also need typed transactional reads through
"Cardano.Node.Client.UTxOIndexer.Provider" use this variant to pass
the same runner to @'Cardano.Node.Client.UTxOIndexer.Provider.withProvider'@.
-}
withInMemoryIndexerRunner ::
    (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) ->
    IO a
withInMemoryIndexerRunner action = do
    db <- mkInMemoryDatabase (mkColumns [0 :: Int ..] indexerCodecs)
    runner <- newRunTransaction db
    bootHandle runner AssetColumnsOn False $ \handle ->
        action handle runner

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
withRocksDBIndexer = withRocksDBIndexerWith defaultOpenOptions

{- | Open a RocksDB-backed indexer and expose both the public
'IndexerHandle' and the underlying transaction runner.

The handle remains the mutation/follower surface; the runner is the
read transaction surface used by the typed provider bridge. Returning
them from the same bracket guarantees the HTTP/server layer reads from
the exact store its chain-sync follower is mutating.
-}
withRocksDBIndexerRunner ::
    FilePath ->
    (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) ->
    IO a
withRocksDBIndexerRunner = withRocksDBIndexerRunnerWith defaultOpenOptions

{- | How a RocksDB store is opened. With 'ooRebuildAssetIndex' a store
whose asset index is not complete is upgraded in place: a store written
before the asset index gains its two column families, and its asset
rows are derived from its own live outputs while the handle serves as
usual. A store already complete, or opened empty, is unaffected.
-}
newtype OpenOptions = OpenOptions
    { ooRebuildAssetIndex :: Bool
    -- ^ Upgrade a store whose asset index is not complete.
    }
    deriving stock (Eq, Show)

-- | The options of 'withRocksDBIndexer': no upgrade.
defaultOpenOptions :: OpenOptions
defaultOpenOptions = OpenOptions{ooRebuildAssetIndex = False}

-- | 'withRocksDBIndexer' with explicit 'OpenOptions'.
withRocksDBIndexerWith ::
    OpenOptions -> FilePath -> (IndexerHandle -> IO a) -> IO a
withRocksDBIndexerWith options path action =
    withRocksDBIndexerRunnerWith options path $ \handle _runner ->
        action handle

{- | 'withRocksDBIndexerRunner' with explicit 'OpenOptions'.

An upgrade in progress runs in a task bound to the action: it starts
before the action, interleaves its bounded transactions with the
action's, is cancelled when the action returns, and continues at the
next open of the store whatever its options. A failure of the task is
rethrown to the action's thread.
-}
withRocksDBIndexerRunnerWith ::
    OpenOptions ->
    FilePath ->
    (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) ->
    IO a
withRocksDBIndexerRunnerWith options path action =
    openIndexerStore options path $ \rdb assetColumns -> do
        let base =
                mkRocksDBDatabase
                    rdb
                    (mkColumns (columnFamilies rdb) (columnsFor assetColumns))
            request = ooRebuildAssetIndex options
        case assetColumns of
            AssetColumnsOn -> do
                runner <- newRunTransaction base
                bootHandle runner assetColumns request $ \handle ->
                    action handle runner
            AssetColumnsOff -> do
                runner <- newRunTransaction (degradedDatabase base)
                bootHandle runner assetColumns request $ \handle ->
                    action handle runner

{- | Which typed columns a store opened with: everything, or only
the four pre-change families (a pre-change directory whose full
open failed on the missing asset/meta families).
-}
data AssetColumns = AssetColumnsOn | AssetColumnsOff
    deriving stock (Eq)

-- | The column codecs that exist for a store shape.
columnsFor :: AssetColumns -> DMap Cols Codecs
columnsFor AssetColumnsOn = indexerCodecs
columnsFor AssetColumnsOff =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        ]

fullFamilies :: [(String, Config)]
fullFamilies =
    [ ("utxo-indexer.txin", def)
    , ("utxo-indexer.address", def)
    , ("utxo-indexer.observation", def)
    , ("utxo-indexer.rollback", def)
    , ("utxo-indexer.asset", def)
    , ("utxo-indexer.meta", def)
    ]

{- | Open a RocksDB store with the full column-family list. When that
fails with RocksDB's "Column family not found" the store predates the
asset index, or an upgrade stopped between creating its two families:
it holds the four pre-change families, possibly followed by the asset
family. Without the upgrade request such a store opens degraded with
the families it has. With the request it gains the missing families
and is then opened with all six. Any other open failure propagates
unchanged, and when no shorter family list opens either, the original
error is the one that escapes.

A degraded store has no asset or metadata columns: asset and marker
maintenance is skipped and the asset read answers 'AssetIndexAbsent';
every other path behaves exactly as on base, including the
provenance-carrying inverses.
-}
openIndexerStore ::
    OpenOptions ->
    FilePath ->
    (DB -> AssetColumns -> IO a) ->
    IO a
openIndexerStore options path action = do
    openedFull <- newIORef False
    full <-
        try @IOException $
            withDBCF path def{createIfMissing = True} fullFamilies $ \rdb -> do
                writeIORef openedFull True
                action rdb AssetColumnsOn
    case full of
        Right a -> pure a
        Left original -> do
            fullOpened <- readIORef openedFull
            if fullOpened || not (isColumnFamilyNotFound original)
                then throwIO original
                else
                    if ooRebuildAssetIndex options
                        then do
                            withPartialFamilies path original $ \rdb n ->
                                createColumnFamilies rdb (drop n fullFamilies)
                            withDBCF path def{createIfMissing = True} fullFamilies $ \rdb ->
                                action rdb AssetColumnsOn
                        else withPartialFamilies path original $ \rdb _ ->
                            action rdb AssetColumnsOff

{- | Run an action on a store opened with the four pre-change families,
or with those four plus the asset family; the action gets how many
families are open. Errors raised once a list has opened propagate;
when neither list opens, the full open's error escapes.
-}
withPartialFamilies ::
    FilePath -> IOException -> (DB -> Int -> IO a) -> IO a
withPartialFamilies path original action = go [4, 5]
  where
    go [] = throwIO original
    go (n : rest) = do
        opened <- newIORef False
        r <-
            try @IOException $
                withDBCF path def{createIfMissing = True} (take n fullFamilies) $ \rdb -> do
                    writeIORef opened True
                    action rdb n
        case r of
            Right a -> pure a
            Left e -> do
                wasOpened <- readIORef opened
                if wasOpened then throwIO e else go rest

-- | Whether an open failure is RocksDB's missing-family error.
isColumnFamilyNotFound :: IOException -> Bool
isColumnFamilyNotFound e =
    "Column family not found" `isInfixOf` show e

{- | A degraded store's column families: the four pre-change real
families, plus an inert family standing in for the asset and
metadata columns. Every operation on the inert family is a total
no-op — reads see nothing, writes and iterations vanish — so any
code path that touches those columns on a degraded store is
harmless by construction, whatever built its handlers.
-}
data StoreCF = StoreCF !ColumnFamily | InertCF

-- | Operations of a degraded store: real RocksDB ops plus no-ops.
data StoreOp = StoreOp !BatchOp | InertOp

{- | Wrap a real database so the asset and metadata columns exist in
the typed surface but resolve to the inert family.
-}
degradedDatabase ::
    Database IO ColumnFamily Cols BatchOp ->
    Database IO StoreCF Cols StoreOp
degradedDatabase real =
    Database
        { valueAt = \cf k -> case cf of
            StoreCF f -> valueAt real f k
            InertCF -> pure Nothing
        , applyOps = \ops ->
            applyOps real [o | StoreOp o <- ops]
        , mkOperation = \cf k mv -> case cf of
            StoreCF f -> StoreOp (mkOperation real f k mv)
            InertCF -> InertOp
        , newIterator = \case
            StoreCF f -> newIterator real f
            InertCF -> pure inertIterator
        , columns =
            DMap.insert MetaCol (Column InertCF metaCodecs) $
                DMap.insert AssetIndex (Column InertCF assetIndexCodecs) $
                    DMap.map
                        (\c -> c{family = StoreCF (family c)})
                        (columns real)
        , withSnapshot = \f ->
            withSnapshot real (f . degradedDatabase)
        }

-- | An iterator over the inert family: always exhausted.
inertIterator :: QueryIterator IO
inertIterator =
    QueryIterator
        { step = \_ -> pure ()
        , isValid = pure False
        , entry = pure Nothing
        }

{- | Final stage shared by both constructors: derive the
initial rollback-log counter from the database, decide the
asset index state, set up the await-state TVars, and hand
the constructed handle to the caller's action.

In one transaction: a store with the rebuild key resumes its
upgrade; a complete store stays complete; a store whose
transaction and rollback columns are both empty gains the
completeness marker; otherwise, when the upgrade is
requested, the rebuild key is written and the upgrade starts.
A store in none of these cases, and every degraded store,
keeps its index absent.
-}
bootHandle ::
    RunTransaction IO cf Cols op ->
    AssetColumns ->
    Bool ->
    (IndexerHandle -> IO a) ->
    IO a
bootHandle runner@RunTransaction{runTransaction} assetColumns request action = do
    (initialCount, rebuilding) <- runTransaction openState
    waitersVar <- newTVarIO Map.empty
    observedVar <- newTVarIO Map.empty
    countVar <- newTVarIO initialCount
    let handle = mkHandle runner assetColumns waitersVar observedVar countVar
    if rebuilding
        then withAsync (rebuildAssetIndex runTransaction) $ \task -> do
            link task
            action handle
        else action handle
  where
    openState = do
        count <- countRollbackEntries
        rebuilding <- case assetColumns of
            AssetColumnsOff -> pure False
            AssetColumnsOn -> decide
        pure (count, rebuilding)
    decide = do
        empty <- isEmptyStore
        marker <- query MetaCol assetIndexCompleteKey
        progress <- query MetaCol assetIndexRebuildKey
        case (progress, marker) of
            (Just _, _) -> pure True
            (Nothing, Just _) -> pure False
            _
                | empty ->
                    False
                        <$ insert MetaCol assetIndexCompleteKey assetIndexCompleteValue
                | request ->
                    True <$ setRebuildProgress (BackfillFrom Nothing)
                | otherwise -> pure False

{- | The metadata key marking a store whose asset index is complete
since the store was created. Written only at open of an empty store;
deleted in the same transaction as any apply or spend whose output
bytes fail asset extraction.
-}
assetIndexCompleteKey :: BS.ByteString
assetIndexCompleteKey = "asset-index"

-- | The marker's v1 value.
assetIndexCompleteValue :: BS.ByteString
assetIndexCompleteValue = BS.singleton 1

{- | The metadata key present while an upgrade of the asset index is in
progress; its value is the upgrade's progress. Never present together
with 'assetIndexCompleteKey'.
-}
assetIndexRebuildKey :: BS.ByteString
assetIndexRebuildKey = "asset-index-rebuild"

{- | Where an upgrade stands: deriving rows from the live outputs after
the given 'TxIn', then sweeping the asset rows after the given key.
-}
data RebuildProgress
    = BackfillFrom !(Maybe TxIn)
    | SweepFrom !(Maybe AssetKey)

{- | Progress bytes, version 1: @0x01@, a phase byte (@0@ backfill,
@1@ sweep), then the last processed key, empty at the phase start.
-}
encodeRebuildProgress :: RebuildProgress -> BS.ByteString
encodeRebuildProgress = \case
    BackfillFrom from -> BS.pack [1, 0] <> maybe BS.empty txInToBytes from
    SweepFrom from -> BS.pack [1, 1] <> maybe BS.empty assetKeyToBytes from

decodeRebuildProgress :: BS.ByteString -> Maybe RebuildProgress
decodeRebuildProgress bytes = case BS.unpack (BS.take 2 bytes) of
    [1, 0] -> BackfillFrom <$> position txInFromBytes
    [1, 1] -> SweepFrom <$> position assetKeyFromBytes
    _ -> Nothing
  where
    rest = BS.drop 2 bytes
    position :: (BS.ByteString -> Maybe k) -> Maybe (Maybe k)
    position decode
        | BS.null rest = Just Nothing
        | otherwise = Just <$> decode rest

setRebuildProgress :: RebuildProgress -> Transaction IO cf Cols op ()
setRebuildProgress =
    insert MetaCol assetIndexRebuildKey . encodeRebuildProgress

-- | Live outputs, or asset rows, handled per upgrade transaction.
rebuildChunkSize :: Int
rebuildChunkSize = 128

{- | Run an upgrade to its end, one bounded transaction at a time. Each
transaction reads the rebuild key first, so an upgrade abandoned by a
follower transaction in between stops here.
-}
rebuildAssetIndex ::
    (forall a. Transaction IO cf Cols op a -> IO a) -> IO ()
rebuildAssetIndex runTx = do
    continue <- runTx rebuildStep
    when continue (rebuildAssetIndex runTx)

{- | One upgrade transaction. The backfill writes, for the next chunk of
live outputs in key order, exactly the rows their stored bytes carry.
The sweep then visits the next chunk of asset rows and deletes or
corrects every row the live outputs do not derive. Finishing the sweep
removes the rebuild key and writes the completeness marker; an output
whose bytes fail extraction removes the rebuild key and leaves the
marker absent. An unreadable progress value restarts the backfill,
which only rewrites derived rows. Returns whether to continue.
-}
rebuildStep :: Transaction IO cf Cols op Bool
rebuildStep = do
    mProgress <- query MetaCol assetIndexRebuildKey
    case decodeRebuildProgress <$> mProgress of
        Nothing -> pure False
        Just Nothing -> True <$ setRebuildProgress (BackfillFrom Nothing)
        Just (Just (BackfillFrom from)) -> do
            entries <- iterating TxInCol (chunkAfter from)
            derived <- traverse (uncurry backfillOne) entries
            advance
                (and derived)
                entries
                (BackfillFrom . Just)
                (True <$ setRebuildProgress (SweepFrom Nothing))
        Just (Just (SweepFrom from)) -> do
            rows <- iterating AssetIndex (chunkAfter from)
            swept <- traverse (uncurry sweepOne) rows
            advance (and swept) rows (SweepFrom . Just) $ do
                delete MetaCol assetIndexRebuildKey
                insert MetaCol assetIndexCompleteKey assetIndexCompleteValue
                pure False
  where
    advance ok chunk next finish
        | not ok = False <$ markAssetIndexIncomplete
        | length chunk < rebuildChunkSize = finish
        | otherwise = case reverse chunk of
            (key, _) : _ -> True <$ setRebuildProgress (next key)
            [] -> finish

-- | Write the rows one live output's stored bytes carry; 'False' when they do not decode.
backfillOne :: TxIn -> Address -> Transaction IO cf Cols op Bool
backfillOne txIn addr = do
    mTxOut <- query AddressIndex (AddrKey addr txIn)
    case decodeTxOutView <$> mTxOut of
        Nothing -> pure True
        Just (Left _err) -> pure False
        Just (Right view) ->
            True
                <$ traverse_
                    (\(policy, name, qty) -> insert AssetIndex (AssetKey policy name txIn) qty)
                    (tovAssets view)

{- | Keep an asset row the live outputs derive, correct its quantity, or
delete it; 'False' when the holding output's bytes do not decode.
-}
sweepOne :: AssetKey -> Word64 -> Transaction IO cf Cols op Bool
sweepOne key@AssetKey{assetKeyPolicy, assetKeyName, assetKeyTxIn} qty = do
    mAddr <- query TxInCol assetKeyTxIn
    mTxOut <- maybe (pure Nothing) (\addr -> query AddressIndex (AddrKey addr assetKeyTxIn)) mAddr
    case decodeTxOutView <$> mTxOut of
        Nothing -> True <$ delete AssetIndex key
        Just (Left _err) -> pure False
        Just (Right view) ->
            True <$ case [q | (p, n, q) <- tovAssets view, p == assetKeyPolicy, n == assetKeyName] of
                [] -> delete AssetIndex key
                q : _ -> when (q /= qty) (insert AssetIndex key q)

-- | Cursor program: up to 'rebuildChunkSize' entries after a key, or from the first.
chunkAfter :: (Monad m, Eq k) => Maybe k -> Cursor m (KV k v) [(k, v)]
chunkAfter from = start >>= go rebuildChunkSize []
  where
    start = case from of
        Nothing -> firstEntry
        Just key ->
            seekKey key >>= \case
                Just Entry{entryKey} | entryKey == key -> nextEntry
                other -> pure other
    go n acc = \case
        Nothing -> pure (reverse acc)
        Just Entry{entryKey, entryValue} ->
            let acc' = (entryKey, entryValue) : acc
             in if n <= 1 then pure (reverse acc') else nextEntry >>= go (n - 1) acc'

{- | Whether no block was ever applied to the store: no live output and
no rollback-log entry.
-}
isEmptyStore :: Transaction IO cf Cols op Bool
isEmptyStore = (&&) <$> isEmptyColumn TxInCol <*> isEmptyColumn RollbackCol

-- | Whether a column holds no entries.
isEmptyColumn ::
    Cols (KV k v) -> Transaction IO cf Cols op Bool
isEmptyColumn col =
    iterating col (isNothing <$> firstEntry)

-- | Shared codec definitions for the indexer columns.
indexerCodecs :: DMap Cols Codecs
indexerCodecs =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        , AssetIndex :=> assetIndexCodecs
        , MetaCol :=> metaCodecs
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
    AssetColumns ->
    Waiters ->
    Observed ->
    TVar Int ->
    IndexerHandle
mkHandle
    RunTransaction{runTransaction}
    assetColumns
    waitersVar
    observedVar
    countVar =
        IndexerHandle
            { applyAtSlot = \slot bh ops -> do
                outcome <- runTransaction (applyAndLog assetColumns slot bh ops)
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
                            (applyRollbackEntry assetColumns)
                            slot
                atomically $ do
                    modifyTVar' countVar (subtract deleted)
                    pruneObservedAfter observedVar slot
            , newFollowerState =
                newIndexerFollowerState
                    runTransaction
                    assetColumns
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
            , assetUtxos = \policy name ->
                case assetColumns of
                    AssetColumnsOff -> pure (Left AssetIndexAbsent)
                    AssetColumnsOn ->
                        runTransaction (readAssetSnapshot policy name)
            , claimBuildCoverage = \requested ->
                case assetColumns of
                    AssetColumnsOff -> pure (Right CoverageUnrecorded)
                    AssetColumnsOn -> runTransaction (claimCoverage requested)
            , readView = \queries ->
                case assetColumns of
                    AssetColumnsOff -> pure (Left AssetIndexAbsent)
                    AssetColumnsOn -> runTransaction (readIndexedView queries)
            }

{- | Retarget an opaque follower state to a handler list.

This is the handler-list seam used by
"Cardano.Node.Client.UTxOIndexer.Follower". The public
'newFollowerState' handle field keeps its historical
@Bool -> IO IndexerFollowerState@ shape and defaults to 'IndexAll';
the follower applies this public helper internally when
'ChainSyncConfig.csHandlers' supplies a richer handler pipeline.

Use @liveUtxoHandler interestSet :| []@ to preserve the normal UTxO
indexer behavior. Consumers that append their own handlers should keep
'liveUtxoHandler' in the list when they still need the standard UTxO
columns. The supplied handlers replace the follower state's phase
handlers together, so restore, follow, and rollback use the same
block-indexer fanout path.
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
        , ifsAssetColumns = assetColumns
        } =
        IndexerFollowerState
            { ifsEngine =
                remapEngineHandlers
                    handlers
                    engine
            , ifsInterestSet = interestSet
            , ifsWaiters = waitersVar
            , ifsObserved = observedVar
            , ifsAssetColumns = assetColumns
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
withFollowerInterest interestSet st@IndexerFollowerState{ifsAssetColumns} =
    withFollowerHandlers
        interestSet
        (liveUtxoHandlerMode ifsAssetColumns interestSet :| [])
        st

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
    AssetColumns ->
    Waiters ->
    Observed ->
    TVar Int ->
    InterestSet ->
    Bool ->
    IO IndexerFollowerState
newIndexerFollowerState
    runTransaction
    assetColumns
    waitersVar
    observedVar
    countVar
    interestSet
    startRestoring = do
        history <- runTransaction (Rollbacks.queryHistory RollbackCol)
        count <- readTVarIO countVar
        let hasFollowingRows =
                any (isJust . rpMeta . snd) history
            handlers = liveUtxoHandlerMode assetColumns interestSet :| []
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
                , ifsAssetColumns = assetColumns
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
        , ifsAssetColumns = _assetColumns
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
                , ifsAssetColumns = _assetColumns
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
        , ifsAssetColumns = assetColumns
        }
    slot = do
        (engine', _deleted) <-
            Engine.rollbackEngineState
                RollbackCol
                (applyRollbackEntry assetColumns)
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
                , ifsAssetColumns = assetColumns
                }

applyOpsOnly ::
    AssetColumns ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    Transaction IO cf Cols op ()
applyOpsOnly assetColumns slot bh =
    traverse_ (applyOne assetColumns slot bh)

{- | Live UTxO storage handler for the generic block-indexer engine.

The handler owns UTxO-specific mutation: interest-set filtering,
inverse creation, applying creates/spends, and applying stored
rollback inverses. The generic block-indexer engine owns only the
rollback-log transaction boundary and phase bookkeeping.

'liveUtxoHandler' keeps its historical signature and maintains the
full column set; internally-constructed handlers carry the store's
shape so a degraded (pre-change, four-family) store skips asset and
marker maintenance.
-}
liveUtxoHandler :: InterestSet -> IndexerHandler Cols [UtxoOp]
liveUtxoHandler = liveUtxoHandlerMode AssetColumnsOn

-- | 'liveUtxoHandler' for a specific store shape.
liveUtxoHandlerMode ::
    AssetColumns -> InterestSet -> IndexerHandler Cols [UtxoOp]
liveUtxoHandlerMode assetColumns interestSet =
    IndexerHandler
        { handlerRestore = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
            applyOpsOnly assetColumns slot bh (filterBlockOps interestSet ops)
        , handlerFollow = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
                followOne op = do
                    inv <- inverseOf op
                    applyOpsOnly assetColumns slot bh [op]
                    pure inv
            reverse
                <$> traverse
                    followOne
                    (filterBlockOps interestSet ops)
        , handlerRollback = \context ops -> do
            let (slot, bh) = utxoContextSlotHash context
            applyOpsOnly assetColumns slot bh ops
        }

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
    AssetColumns ->
    SlotNo ->
    BlockHash ->
    [UtxoOp] ->
    Transaction IO cf Cols op (Engine.ApplyLogResult BlockHash)
applyAndLog assetColumns slot bh ops =
    Engine.applyWithRollbackLog
        RollbackCol
        slot
        bh
        applyFresh
  where
    applyFresh =
        Handler.followHandlers
            (liveUtxoHandlerMode assetColumns IndexAll :| [])
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
    go (UtxoCreate txIn _addr txOut) =
        observe txIn slot bh txOut
    go (UtxoRestore txIn _addr txOut obsSlot obsBh) =
        observe txIn obsSlot obsBh txOut
    go (UtxoSpend txIn) =
        modifyTVar' observedVar (Map.delete txIn)
    observe txIn obsSlot obsBh txOut = do
        let obs =
                AwaitObservation
                    { aoSlot = obsSlot
                    , aoBlockHash = obsBh
                    , aoTxOut = txOut
                    }
        modifyTVar' observedVar (Map.insert txIn obs)
        waiters <- readTVar waitersVar
        case Map.lookup txIn waiters of
            Nothing -> pure ()
            Just ws -> do
                writeTVar waitersVar (Map.delete txIn waiters)
                traverse_ (`putTMVar` obs) ws

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
    AssetColumns ->
    SlotNo ->
    Maybe BlockHash ->
    [[UtxoOp]] ->
    Transaction IO cf Cols op ()
applyRollbackEntry assetColumns slot (Just bh) invBatches =
    traverse_
        ( Handler.rollbackHandlers
            (liveUtxoHandlerMode assetColumns IndexAll :| [])
            HandlerContext
                { hcSlot = slot
                , hcMeta = Just bh
                }
        )
        invBatches
applyRollbackEntry _assetColumns _slot Nothing [] =
    pure ()
applyRollbackEntry _assetColumns _slot Nothing (_ : _) =
    error
        "applyRollbackEntry: sentinel RollbackPoint carries \
        \inverse operations — schema drift"

{- | Inverse of a single op against current state.

The inverse of a spend (or of a re-create over a live 'TxIn') is a
'UtxoRestore' carrying the output's original creation point, read
from 'ObservationCol' in the same transaction before the op is
applied — so a rollback re-creates the output with its original
provenance instead of the rollback slot. When no observation is
recorded (a state the live-data invariant excludes) the inverse
falls back to the pre-change 'UtxoCreate' shape, which applies with
the applying block's point.
-}
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
                Just txOut -> do
                    mObs <- query ObservationCol txIn
                    case mObs of
                        Just (createdSlot, createdBh) ->
                            pure
                                ( UtxoRestore
                                    txIn
                                    addr
                                    txOut
                                    createdSlot
                                    createdBh
                                )
                        Nothing -> pure (UtxoCreate txIn addr txOut)
                Nothing -> pure (UtxoSpend txIn)

opTxIn :: UtxoOp -> TxIn
opTxIn (UtxoCreate t _ _) = t
opTxIn (UtxoSpend t) = t
opTxIn (UtxoRestore t _ _ _ _) = t

{- | Apply one op against the column state. The
@(slot, bh)@ pair is recorded into 'ObservationCol' on
'UtxoCreate' so 'awaitTxIn' can answer the
"already observed?" fast-path question across process
restart; on 'UtxoSpend' the corresponding observation is
removed. 'UtxoRestore' re-creates a spent output recording
its original creation point instead of the applying block's.
-}
applyOne ::
    AssetColumns ->
    SlotNo ->
    BlockHash ->
    UtxoOp ->
    Transaction IO cf Cols op ()
applyOne assetColumns slot bh = \case
    UtxoCreate txIn addr txOut ->
        createTxIn assetColumns slot bh txIn addr txOut
    UtxoRestore txIn addr txOut createdSlot createdBh ->
        createTxIn assetColumns createdSlot createdBh txIn addr txOut
    UtxoSpend txIn -> do
        mAddr <- query TxInCol txIn
        case mAddr of
            Nothing -> pure ()
            Just addr -> do
                mTxOut <- query AddressIndex (AddrKey addr txIn)
                delete AddressIndex (AddrKey addr txIn)
                delete TxInCol txIn
                delete ObservationCol txIn
                maintainAssetsOnSpend assetColumns txIn mTxOut

createTxIn ::
    AssetColumns ->
    SlotNo ->
    BlockHash ->
    TxIn ->
    Address ->
    TxOut ->
    Transaction IO cf Cols op ()
createTxIn assetColumns slot bh txIn addr txOut = do
    -- A create over an already-live TxIn (or a restore of its
    -- pre-image) replaces the stored output: reconcile the previous
    -- output's asset rows away inside the same transaction, so the
    -- rows always mirror the bytes that are actually live.
    mOldAddr <- query TxInCol txIn
    case mOldAddr of
        Just oldAddr -> do
            mOldOut <- query AddressIndex (AddrKey oldAddr txIn)
            maintainAssetsOnSpend assetColumns txIn mOldOut
        Nothing -> pure ()
    insert TxInCol txIn addr
    insert AddressIndex (AddrKey addr txIn) txOut
    insert ObservationCol txIn (slot, bh)
    maintainAssetsOnCreate assetColumns txIn txOut

{- | Asset maintenance on create: write exactly the asset rows the
stored output's bytes carry. An undecodable output deletes the
completeness marker. Skipped entirely on a degraded store, whose
columns do not exist.
-}
maintainAssetsOnCreate ::
    AssetColumns ->
    TxIn ->
    TxOut ->
    Transaction IO cf Cols op ()
maintainAssetsOnCreate AssetColumnsOff _ _ = pure ()
maintainAssetsOnCreate AssetColumnsOn txIn txOut =
    case decodeTxOutView txOut of
        Left _err -> markAssetIndexIncomplete
        Right view ->
            traverse_
                (\(policy, name, qty) -> insert AssetIndex (AssetKey policy name txIn) qty)
                (tovAssets view)

{- | Asset maintenance on spend: re-extract the asset rows from the
stored output being removed and delete exactly those. The stored
bytes are read before the deletion in the same transaction.
-}
maintainAssetsOnSpend ::
    AssetColumns ->
    TxIn ->
    Maybe TxOut ->
    Transaction IO cf Cols op ()
maintainAssetsOnSpend AssetColumnsOff _ _ = pure ()
maintainAssetsOnSpend AssetColumnsOn txIn mTxOut =
    case decodeTxOutView <$> mTxOut of
        Just (Right view) ->
            traverse_
                (\(policy, name, _qty) -> delete AssetIndex (AssetKey policy name txIn))
                (tovAssets view)
        Just (Left _err) -> markAssetIndexIncomplete
        Nothing -> pure ()

{- | Delete the completeness marker and the rebuild key in the current
transaction: the asset index is no longer known complete and cannot
become complete by an upgrade in progress, so reads must answer
unavailability instead of a partial list.
-}
markAssetIndexIncomplete :: Transaction IO cf Cols op ()
markAssetIndexIncomplete = do
    delete MetaCol assetIndexCompleteKey
    delete MetaCol assetIndexRebuildKey

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

{- | Cursor program: seek to the synthetic minimum key under one
asset and walk forward, collecting the holding 'TxIn's with their
quantities in ascending 'TxIn' order. The composite key layout
keeps one asset's rows contiguous, so the walk stops at the first
key of another asset.
-}
scanAsset ::
    (Monad m) =>
    PolicyId ->
    AssetName ->
    Cursor m (KV AssetKey Word64) [(TxIn, Word64)]
scanAsset policy name =
    let seekTo =
            AssetKey
                policy
                name
                (TxIn (BS.replicate 32 0) 0)
     in seekKey seekTo >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = k, entryValue = q})
        | assetKeyPolicy k == policy && assetKeyName k == name =
            nextEntry >>= go ((assetKeyTxIn k, q) : acc)
        | otherwise = pure (reverse acc)

{- | The indexed point: the newest rollback-log row carrying
block-hash metadata, read backwards from the tip. A store with no
following row (empty, or restoration-only) has no point.
-}
indexedPoint ::
    Transaction IO cf Cols op (Maybe (SlotNo, BlockHash))
indexedPoint =
    iterating RollbackCol (lastEntry >>= loop)
  where
    loop Nothing = pure Nothing
    loop (Just Entry{entryKey = slot, entryValue = rp}) =
        case rpMeta rp of
            Just bh -> pure (Just (slot, bh))
            Nothing -> prevEntry >>= loop

{- | The typed asset read, all in one transaction: the indexed
point, the asset rows for the queried asset, and the join back to
the live columns for the stored bytes and creation point. A row
whose 'TxIn' lacks live data makes the whole read inconsistent.
-}
readAssetSnapshot ::
    PolicyId ->
    AssetName ->
    Transaction IO cf Cols op (Either AssetQueryUnavailable AssetSnapshot)
readAssetSnapshot = readAssetSnapshotCore

{- | Transactional asset-read core shared by the legacy 'assetUtxos'
path and the indexed view. The legacy snapshot-binding fault rewrites
the wrapper above; the core stays single-transaction for the view.
-}
readAssetSnapshotCore ::
    PolicyId ->
    AssetName ->
    Transaction IO cf Cols op (Either AssetQueryUnavailable AssetSnapshot)
readAssetSnapshotCore policy name = do
    mRebuild <- query MetaCol assetIndexRebuildKey
    mMarker <- query MetaCol assetIndexCompleteKey
    case (mRebuild, mMarker) of
        (Just _, _) -> pure (Left AssetIndexRebuilding)
        (Nothing, Just v) | v == assetIndexCompleteValue -> readComplete
        _ -> pure (Left AssetIndexAbsent)
  where
    readComplete = do
        mPoint <- indexedPoint
        case mPoint of
            Nothing -> pure (Left NoIndexedPoint)
            Just point -> do
                rows <- iterating AssetIndex (scanAsset policy name)
                result <- traverse matchOf rows
                pure (fmap (AssetSnapshot point) (sequenceA result))

    matchOf (txIn, qty) = do
        mAddr <- query TxInCol txIn
        case mAddr of
            Nothing -> pure (Left (AssetIndexInconsistent txIn))
            Just addr -> do
                mOut <- query AddressIndex (AddrKey addr txIn)
                case mOut of
                    Nothing -> pure (Left (AssetIndexInconsistent txIn))
                    Just txOut -> do
                        mObs <- query ObservationCol txIn
                        case mObs of
                            Nothing -> pure (Left (AssetIndexInconsistent txIn))
                            Just (slot, bh) ->
                                pure
                                    ( Right
                                        ( AssetMatch
                                            { amTxIn = txIn
                                            , amTxOut = txOut
                                            , amQuantity = qty
                                            , amCreatedSlot = slot
                                            , amCreatedBlockHash = bh
                                            }
                                        )
                                    )

-- | Availability and indexed point for the entire batch, even address-only.
readViewPoint ::
    Transaction IO cf Cols op (Either AssetQueryUnavailable (SlotNo, BlockHash))
readViewPoint = do
    rebuilding <- query MetaCol assetIndexRebuildKey
    complete <- query MetaCol assetIndexCompleteKey
    case (rebuilding, complete) of
        (Just _, _) -> pure (Left AssetIndexRebuilding)
        (Nothing, Just v) | v == assetIndexCompleteValue -> do
            maybe (Left NoIndexedPoint) Right <$> indexedPoint
        _ -> pure (Left AssetIndexAbsent)

-- | Resolve one query inside the enclosing view transaction.
readViewResult ::
    ReadQuery ->
    Transaction IO cf Cols op (Either AssetQueryUnavailable ReadResult)
readViewResult (AddressQuery addr) =
    Right . AddressResult <$> iterating AddressIndex (scanAddress addr)
readViewResult (AssetQuery policy name) =
    fmap (AssetResult . asMatches) <$> readAssetSnapshotCore policy name

{- | Point, markers, address scans and asset joins all use the runner's
single snapshot. Only materialized values leave the transaction.
-}
readIndexedView ::
    NonEmpty ReadQuery ->
    Transaction IO cf Cols op (Either AssetQueryUnavailable IndexedView)
readIndexedView queries = do
    point <- readViewPoint
    case point of
        Left reason -> pure (Left reason)
        Right p -> do
            results <- traverse readViewResult queries
            pure (IndexedView p <$> sequenceA results)

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
