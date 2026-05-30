{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Indexer
License     : Apache-2.0
Description : Multi-tenant tx-history indexer state and API

Holds the tx-history indexer's state behind a backend-agnostic
'HistoryIndexer' handle.

Slice 1 operations:

* 'appendSummaries' files a batch of detailed 'TxSummary' rows under
  their ordered composite keys and maintains a tenant-local tx-id
  lookup.
* 'appendHistory' is the legacy empty-detail wrapper over
  'appendSummaries'.
* 'queryHistory' returns every entry of a single
  @(tenant, scope)@, ordered by @(slot, txid, role)@.

Slice 2 adds the slot-aware, resumable surface the shared chain-sync
follower drives (the plan's cursor model 2: a same chain-sync session
drives the UTxO indexer and the history indexer through /separate
persisted cursors/, and resume picks the oldest safe point across both
stores):

* 'processHistoryBlock' files a block's entries and records a
  @(slot, blockHash)@ rollback/resume point in the same write.
* 'rollbackHistoryTo' drops every entry filed strictly above a target
  slot, reversing the blocks above it.
* 'getHistoryResumePoints' returns the retained @(slot, blockHash)@
  points newest-first, for the follower's resume negotiation.

Because the history store is a separate RocksDB database from the UTxO
store, a per-block write across the two stores is not atomic. The
cursor model tolerates this: 'processHistoryBlock' is idempotent in the
block slot (replaying an already-applied block overwrites the same
keys), and resume from the oldest safe point re-applies any block a
mid-write crash left in only one store.

Two backends share the same handle and surface:

* 'withInMemoryHistoryIndexer' keeps a 'TVar' over a 'Map' from the
  ordered composite-key bytes ('summaryKeyToBytes') to the entry, plus
  a 'Map' from chain slot to the block's 'HistoryBlock' rollback row.
* 'withRocksDBHistoryIndexer' uses a @kv-transactions@ RocksDB
  'Database' keyed by the 'Cols' GADT; the same ordered key codec
  drives the on-disk byte order. Direct tx-id lookup rows live in the
  entries column under an internal reserved key namespace, and the
  'HistoryBlockCol' column persists the rollback/resume log.
-}
module Cardano.Node.Client.TxHistoryIndexer.Indexer (
    -- * Indexer handle
    HistoryIndexer (..),
    withInMemoryHistoryIndexer,
    withRocksDBHistoryIndexer,

    -- * Slice 1 operations
    appendHistory,
    appendSummaries,
    queryHistory,
    getByTxId,

    -- * Slice 2 block/rollback/resume operations
    processHistoryBlock,
    rollbackHistoryTo,
    getHistoryResumePoints,
) where

import Cardano.Node.Client.TxHistoryIndexer.Columns (
    Cols (..),
    HistoryBlock (..),
    historyCodecs,
 )
import Cardano.Node.Client.TxHistoryIndexer.Types (
    HistoryScope (..),
    TenantId (..),
    TxDirection (..),
    TxId (..),
    TxIdKey (..),
    TxRole (..),
    TxSummary (..),
    TxSummaryEntry (..),
    TxSummaryKey (..),
    TxSummaryValue (..),
    entryToSummary,
    scopePrefix,
    summaryFromValue,
    summaryKeyFromBytes,
    summaryKeyToBytes,
    summaryToEntry,
    summaryValueOf,
    txIdKeyOf,
    txIdKeyToBytes,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Concurrent.STM (
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
 )
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    firstEntry,
    nextEntry,
    seekKey,
 )
import Database.KV.Database (KV, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    RunTransaction (..),
    Transaction,
    delete,
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

{- | Backend-agnostic handle to a tx-history indexer. Both the
in-memory and RocksDB backends provide the same operations.
-}
data HistoryIndexer = HistoryIndexer
    { hiAppendSummaries :: [TxSummary] -> IO ()
    -- ^ File a batch of detailed summaries under their ordered keys.
    , hiQuery :: TenantId -> HistoryScope -> IO [TxSummaryEntry]
    -- ^ Return every entry of @(tenant, scope)@, ordered by
    -- @(slot, txid, role)@.
    , hiGetByTxId :: TenantId -> TxId -> IO (Maybe TxSummary)
    -- ^ Directly look up a detailed summary by tenant-local tx id.
    , hiProcessBlock ::
        SlotNo ->
        ByteString ->
        [TxSummary] ->
        IO ()
    -- ^ File a block's entries and record its
    -- @(slot, blockHash)@ rollback/resume point.
    , hiRollbackTo :: SlotNo -> IO ()
    -- ^ Drop every entry filed strictly above a target slot.
    , hiResumePoints :: IO [(SlotNo, ByteString)]
    -- ^ Retained @(slot, blockHash)@ resume points, newest-first.
    }

{- | File a batch of history entries. Each entry is keyed by its
ordered composite-key bytes ('summaryKeyToBytes').
-}
appendHistory :: HistoryIndexer -> [TxSummaryEntry] -> IO ()
appendHistory indexer = appendSummaries indexer . fmap entryToSummary

{- | File a batch of detailed history summaries. Each summary is keyed
by its ordered composite-key bytes ('summaryKeyToBytes') and is also
available through 'getByTxId'.
-}
appendSummaries :: HistoryIndexer -> [TxSummary] -> IO ()
appendSummaries = hiAppendSummaries

{- | Return every entry filed under @(tenant, scope)@, ordered
by @(slot, txid, role)@. Entries of other tenants or scopes —
including strict byte-prefix neighbours — are excluded.
-}
queryHistory ::
    HistoryIndexer ->
    TenantId ->
    HistoryScope ->
    IO [TxSummaryEntry]
queryHistory = hiQuery

{- | Return the detailed summary for a tenant-local transaction id.
This is a direct lookup via the secondary index; it does not scan
scopes or call a node.
-}
getByTxId ::
    HistoryIndexer ->
    TenantId ->
    TxId ->
    IO (Maybe TxSummary)
getByTxId = hiGetByTxId

{- | File a block's history entries and record a @(slot, blockHash)@
rollback/resume point in the same write. Idempotent in the block slot:
re-applying an already-applied block overwrites the same keys and the
same rollback row, so a query result is unchanged.
-}
processHistoryBlock ::
    HistoryIndexer ->
    SlotNo ->
    ByteString ->
    [TxSummary] ->
    IO ()
processHistoryBlock = hiProcessBlock

{- | Drop every history entry filed strictly above the target slot,
reversing the blocks above it. Entries filed at or below the target
remain.
-}
rollbackHistoryTo :: HistoryIndexer -> SlotNo -> IO ()
rollbackHistoryTo = hiRollbackTo

{- | The retained @(slot, blockHash)@ resume points, newest-first.
@[]@ on a fresh store (cold boot).
-}
getHistoryResumePoints :: HistoryIndexer -> IO [(SlotNo, ByteString)]
getHistoryResumePoints = hiResumePoints

-- In-memory backend ------------------------------------------------

{- | In-memory store: the ordered entry map plus the per-block
rollback/resume log.
-}
data MemState = MemState
    { msEntries :: !(Map ByteString TxSummary)
    , msByTxId :: !(Map ByteString TxSummary)
    , msBlocks :: !(Map SlotNo HistoryBlock)
    }

emptyMemState :: MemState
emptyMemState = MemState Map.empty Map.empty Map.empty

{- | Open an in-memory tx-history indexer, run the action with
the handle, and discard the store on exit. The store starts
empty.
-}
withInMemoryHistoryIndexer :: (HistoryIndexer -> IO a) -> IO a
withInMemoryHistoryIndexer action = do
    store <- newTVarIO emptyMemState
    action
        HistoryIndexer
            { hiAppendSummaries = memAppendSummaries store
            , hiQuery = memQuery store
            , hiGetByTxId = memGetByTxId store
            , hiProcessBlock = memProcessBlock store
            , hiRollbackTo = memRollbackTo store
            , hiResumePoints = memResumePoints store
            }

insertSummary ::
    Map ByteString TxSummary ->
    TxSummary ->
    Map ByteString TxSummary
insertSummary m summary =
    case summaryKeyToBytes (txsKey summary) of
        Nothing -> m
        Just k -> Map.insert k summary m

insertTxIdSummary ::
    Map ByteString TxSummary ->
    TxSummary ->
    Map ByteString TxSummary
insertTxIdSummary m summary =
    case txIdKeyToBytes (txIdKeyOf (txsKey summary)) of
        Nothing -> m
        Just k -> Map.insert k summary m

memAppendSummaries :: TVar MemState -> [TxSummary] -> IO ()
memAppendSummaries store summaries =
    atomically $ modifyTVar' store $ \st ->
        st
            { msEntries = foldl insertSummary (msEntries st) summaries
            , msByTxId = foldl insertTxIdSummary (msByTxId st) summaries
            }

memProcessBlock ::
    TVar MemState ->
    SlotNo ->
    ByteString ->
    [TxSummary] ->
    IO ()
memProcessBlock store slot hash summaries0 =
    let summaries = stampBlockHash hash summaries0
     in atomically $ modifyTVar' store $ \st ->
            st
                { msEntries = foldl insertSummary (msEntries st) summaries
                , msByTxId = foldl insertTxIdSummary (msByTxId st) summaries
                , msBlocks =
                    Map.insert
                        slot
                        (HistoryBlock hash (txsKey <$> summaries))
                        (msBlocks st)
                }

stampBlockHash :: ByteString -> [TxSummary] -> [TxSummary]
stampBlockHash hash =
    fmap $ \summary -> summary{txsBlockHash = Just hash}

memRollbackTo :: TVar MemState -> SlotNo -> IO ()
memRollbackTo store target =
    atomically $ modifyTVar' store $ \st ->
        let (keep, stale) =
                Map.partitionWithKey
                    (\s _ -> s <= target)
                    (msBlocks st)
            staleKeyBytes =
                [ kb
                | hb <- Map.elems stale
                , k <- hbEntryKeys hb
                , Just kb <- [summaryKeyToBytes k]
                ]
            staleTxIdKeyBytes =
                [ kb
                | hb <- Map.elems stale
                , k <- hbEntryKeys hb
                , Just kb <- [txIdKeyToBytes (txIdKeyOf k)]
                ]
         in st
                { msEntries =
                    foldl (flip Map.delete) (msEntries st) staleKeyBytes
                , msByTxId =
                    foldl (flip Map.delete) (msByTxId st) staleTxIdKeyBytes
                , msBlocks = keep
                }

memResumePoints :: TVar MemState -> IO [(SlotNo, ByteString)]
memResumePoints store = do
    st <- readTVarIO store
    pure
        [ (slot, hbBlockHash hb)
        | (slot, hb) <- Map.toDescList (msBlocks st)
        ]

memQuery ::
    TVar MemState ->
    TenantId ->
    HistoryScope ->
    IO [TxSummaryEntry]
memQuery store tenant scope = do
    st <- readTVarIO store
    pure $ case scopePrefix tenant scope of
        Nothing -> []
        Just prefix ->
            [ summaryToEntry summary
            | (k, summary) <- Map.toAscList (msEntries st)
            , prefix `BS.isPrefixOf` k
            ]

memGetByTxId ::
    TVar MemState ->
    TenantId ->
    TxId ->
    IO (Maybe TxSummary)
memGetByTxId store tenant txid = do
    st <- readTVarIO store
    pure $ do
        keyBytes <- txIdKeyToBytes (TxIdKey tenant txid)
        Map.lookup keyBytes (msByTxId st)

-- RocksDB backend --------------------------------------------------

{- | Open a RocksDB-backed tx-history indexer at @path@ (creating
the directory tree if missing) and run the action with the
handle. The on-disk store survives process restart.

Two column families are created: @tx-history.entries@ (the
'HistoryCol' table, including reserved direct-lookup rows) and
@tx-history.blocks@ (the 'HistoryBlockCol' rollback/resume log).
-}
withRocksDBHistoryIndexer ::
    FilePath -> (HistoryIndexer -> IO a) -> IO a
withRocksDBHistoryIndexer path action =
    withDBCF
        path
        def{createIfMissing = True}
        [ ("tx-history.entries", def)
        , ("tx-history.blocks", def)
        ]
        $ \rdb -> do
            let database =
                    mkRocksDBDatabase
                        rdb
                        (mkColumns (columnFamilies rdb) historyCodecs)
            runner <- newRunTransaction database
            action
                HistoryIndexer
                    { hiAppendSummaries = rocksAppendSummaries runner
                    , hiQuery = rocksQuery runner
                    , hiGetByTxId = rocksGetByTxId runner
                    , hiProcessBlock = rocksProcessBlock runner
                    , hiRollbackTo = rocksRollbackTo runner
                    , hiResumePoints = rocksResumePoints runner
                    }

rocksAppendSummaries ::
    RunTransaction IO cf Cols op ->
    [TxSummary] ->
    IO ()
rocksAppendSummaries RunTransaction{runTransaction} summaries =
    runTransaction $
        forM_ summaries insertSummaryRows

rocksProcessBlock ::
    RunTransaction IO cf Cols op ->
    SlotNo ->
    ByteString ->
    [TxSummary] ->
    IO ()
rocksProcessBlock RunTransaction{runTransaction} slot hash summaries0 =
    let summaries = stampBlockHash hash summaries0
     in runTransaction $ do
            forM_ summaries insertSummaryRows
            insert
                HistoryBlockCol
                slot
                (HistoryBlock hash (txsKey <$> summaries))

insertSummaryRows ::
    TxSummary ->
    Transaction IO cf Cols op ()
insertSummaryRows summary = do
    insert HistoryCol (txsKey summary) (summaryValueOf summary)
    insert HistoryCol (txIdLookupKeyOf (txsKey summary)) (summaryKeyRefValue (txsKey summary))

rocksRollbackTo ::
    RunTransaction IO cf Cols op ->
    SlotNo ->
    IO ()
rocksRollbackTo RunTransaction{runTransaction} target =
    runTransaction $ do
        rows <- iterating HistoryBlockCol collectAllBlocks
        forM_ rows $ \(slot, hb) ->
            when (slot > target) $ do
                forM_ (hbEntryKeys hb) $ \key -> do
                    delete HistoryCol key
                    delete HistoryCol (txIdLookupKeyOf key)
                delete HistoryBlockCol slot

rocksResumePoints ::
    RunTransaction IO cf Cols op ->
    IO [(SlotNo, ByteString)]
rocksResumePoints RunTransaction{runTransaction} =
    runTransaction $ do
        rows <- iterating HistoryBlockCol collectAllBlocks
        pure $ reverse [(slot, hbBlockHash hb) | (slot, hb) <- rows]

rocksQuery ::
    RunTransaction IO cf Cols op ->
    TenantId ->
    HistoryScope ->
    IO [TxSummaryEntry]
rocksQuery RunTransaction{runTransaction} tenant scope =
    runTransaction $
        iterating HistoryCol (scanHistory tenant scope)

rocksGetByTxId ::
    RunTransaction IO cf Cols op ->
    TenantId ->
    TxId ->
    IO (Maybe TxSummary)
rocksGetByTxId RunTransaction{runTransaction} tenant txid =
    runTransaction $ do
        mKeyValue <- query HistoryCol (txIdLookupKey tenant txid)
        case mKeyValue >>= summaryKeyFromBytes . tsvPayload of
            Nothing -> pure Nothing
            Just key -> fmap (summaryFromValue key) <$> query HistoryCol key

txIdLookupKeyOf :: TxSummaryKey -> TxSummaryKey
txIdLookupKeyOf TxSummaryKey{tskTenant, tskTxId} =
    txIdLookupKey tskTenant tskTxId

{- | Reserved key namespace for the direct txid lookup row stored in
'HistoryCol'. Keeping the lookup inside the existing entries column
lets an already-created two-column RocksDB database open after this
schema extension.
-}
txIdLookupKey :: TenantId -> TxId -> TxSummaryKey
txIdLookupKey (TenantId tenant) txid =
    TxSummaryKey
        { tskTenant = TenantId "\NULtx-history-by-txid"
        , tskScope = HistoryScope tenant
        , tskSlot = SlotNo 0
        , tskTxId = txid
        , tskRole = TxRole "\NULlookup"
        }

summaryKeyRefValue :: TxSummaryKey -> TxSummaryValue
summaryKeyRefValue key =
    TxSummaryValue
        { tsvPayload = fromMaybe BS.empty (summaryKeyToBytes key)
        , tsvInputs = []
        , tsvOutputs = []
        , tsvRedeemer = Nothing
        , tsvFee = Nothing
        , tsvRequiredSigners = []
        , tsvBlockHash = Nothing
        , tsvDirection = TxDirection "outbound"
        }

{- | Cursor program: collect every row of the per-block
rollback/resume log in ascending slot order.
-}
collectAllBlocks ::
    (Monad m) =>
    Cursor m (KV SlotNo HistoryBlock) [(SlotNo, HistoryBlock)]
collectAllBlocks = firstEntry >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = k, entryValue = v}) =
        nextEntry >>= go ((k, v) : acc)

{- | Cursor program: seek to the synthetic minimum key under
@(tenant, scope)@ and walk forward, collecting every entry whose
ordered key still carries the @(tenant, scope)@ prefix.
-}
scanHistory ::
    (Monad m) =>
    TenantId ->
    HistoryScope ->
    Cursor m (KV TxSummaryKey TxSummaryValue) [TxSummaryEntry]
scanHistory tenant scope =
    let seekTo =
            TxSummaryKey
                { tskTenant = tenant
                , tskScope = scope
                , tskSlot = SlotNo 0
                , tskTxId = TxId BS.empty
                , tskRole = TxRole BS.empty
                }
     in seekKey seekTo >>= go []
  where
    mPrefix = scopePrefix tenant scope
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = k, entryValue = v}) =
        case (mPrefix, summaryKeyToBytes k) of
            (Just prefix, Just kBytes)
                | prefix `BS.isPrefixOf` kBytes ->
                    nextEntry >>= go (summaryToEntry (summaryFromValue k v) : acc)
            _ -> pure (reverse acc)
