{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Indexer
License     : Apache-2.0
Description : Multi-tenant tx-history indexer state and API

Holds the tx-history indexer's state behind a backend-agnostic
'HistoryIndexer' handle.

Slice 1 operations:

* 'appendHistory' files a batch of 'TxSummaryEntry' under their
  ordered composite keys.
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
  drives the on-disk byte order, and the 'HistoryBlockCol' column
  persists the rollback/resume log.
-}
module Cardano.Node.Client.TxHistoryIndexer.Indexer (
    -- * Indexer handle
    HistoryIndexer (..),
    withInMemoryHistoryIndexer,
    withRocksDBHistoryIndexer,

    -- * Slice 1 operations
    appendHistory,
    queryHistory,

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
    HistoryScope,
    TenantId,
    TxId (..),
    TxRole (..),
    TxSummaryEntry (..),
    TxSummaryKey (..),
    scopePrefix,
    summaryKeyToBytes,
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
    delete,
    insert,
    iterating,
    newRunTransaction,
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
    { hiAppend :: [TxSummaryEntry] -> IO ()
    -- ^ File a batch of entries under their ordered keys.
    , hiQuery :: TenantId -> HistoryScope -> IO [TxSummaryEntry]
    -- ^ Return every entry of @(tenant, scope)@, ordered by
    -- @(slot, txid, role)@.
    , hiProcessBlock ::
        SlotNo ->
        ByteString ->
        [TxSummaryEntry] ->
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
appendHistory = hiAppend

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

{- | File a block's history entries and record a @(slot, blockHash)@
rollback/resume point in the same write. Idempotent in the block slot:
re-applying an already-applied block overwrites the same keys and the
same rollback row, so a query result is unchanged.
-}
processHistoryBlock ::
    HistoryIndexer ->
    SlotNo ->
    ByteString ->
    [TxSummaryEntry] ->
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
    { msEntries :: !(Map ByteString TxSummaryEntry)
    , msBlocks :: !(Map SlotNo HistoryBlock)
    }

emptyMemState :: MemState
emptyMemState = MemState Map.empty Map.empty

{- | Open an in-memory tx-history indexer, run the action with
the handle, and discard the store on exit. The store starts
empty.
-}
withInMemoryHistoryIndexer :: (HistoryIndexer -> IO a) -> IO a
withInMemoryHistoryIndexer action = do
    store <- newTVarIO emptyMemState
    action
        HistoryIndexer
            { hiAppend = memAppend store
            , hiQuery = memQuery store
            , hiProcessBlock = memProcessBlock store
            , hiRollbackTo = memRollbackTo store
            , hiResumePoints = memResumePoints store
            }

insertEntry ::
    Map ByteString TxSummaryEntry ->
    TxSummaryEntry ->
    Map ByteString TxSummaryEntry
insertEntry m entry =
    case summaryKeyToBytes (tseKey entry) of
        Nothing -> m
        Just k -> Map.insert k entry m

memAppend :: TVar MemState -> [TxSummaryEntry] -> IO ()
memAppend store entries =
    atomically $ modifyTVar' store $ \st ->
        st{msEntries = foldl insertEntry (msEntries st) entries}

memProcessBlock ::
    TVar MemState ->
    SlotNo ->
    ByteString ->
    [TxSummaryEntry] ->
    IO ()
memProcessBlock store slot hash entries =
    atomically $ modifyTVar' store $ \st ->
        st
            { msEntries = foldl insertEntry (msEntries st) entries
            , msBlocks =
                Map.insert
                    slot
                    (HistoryBlock hash (tseKey <$> entries))
                    (msBlocks st)
            }

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
         in st
                { msEntries =
                    foldl (flip Map.delete) (msEntries st) staleKeyBytes
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
            [ entry
            | (k, entry) <- Map.toAscList (msEntries st)
            , prefix `BS.isPrefixOf` k
            ]

-- RocksDB backend --------------------------------------------------

{- | Open a RocksDB-backed tx-history indexer at @path@ (creating
the directory tree if missing) and run the action with the
handle. The on-disk store survives process restart.

Two column families are created: @tx-history.entries@ (the
'HistoryCol' table) and @tx-history.blocks@ (the 'HistoryBlockCol'
rollback/resume log).
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
                    { hiAppend = rocksAppend runner
                    , hiQuery = rocksQuery runner
                    , hiProcessBlock = rocksProcessBlock runner
                    , hiRollbackTo = rocksRollbackTo runner
                    , hiResumePoints = rocksResumePoints runner
                    }

rocksAppend ::
    RunTransaction IO cf Cols op ->
    [TxSummaryEntry] ->
    IO ()
rocksAppend RunTransaction{runTransaction} entries =
    runTransaction $
        mapM_
            (\e -> insert HistoryCol (tseKey e) (tsePayload e))
            entries

rocksProcessBlock ::
    RunTransaction IO cf Cols op ->
    SlotNo ->
    ByteString ->
    [TxSummaryEntry] ->
    IO ()
rocksProcessBlock RunTransaction{runTransaction} slot hash entries =
    runTransaction $ do
        mapM_
            (\e -> insert HistoryCol (tseKey e) (tsePayload e))
            entries
        insert
            HistoryBlockCol
            slot
            (HistoryBlock hash (tseKey <$> entries))

rocksRollbackTo ::
    RunTransaction IO cf Cols op ->
    SlotNo ->
    IO ()
rocksRollbackTo RunTransaction{runTransaction} target =
    runTransaction $ do
        rows <- iterating HistoryBlockCol collectAllBlocks
        forM_ rows $ \(slot, hb) ->
            when (slot > target) $ do
                mapM_ (delete HistoryCol) (hbEntryKeys hb)
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
    Cursor m (KV TxSummaryKey ByteString) [TxSummaryEntry]
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
                    nextEntry >>= go (TxSummaryEntry k v : acc)
            _ -> pure (reverse acc)
