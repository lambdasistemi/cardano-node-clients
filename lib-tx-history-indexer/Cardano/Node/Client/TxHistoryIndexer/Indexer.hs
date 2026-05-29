{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Indexer
License     : Apache-2.0
Description : Multi-tenant tx-history indexer state and API

Holds the tx-history indexer's state behind a backend-agnostic
'HistoryIndexer' handle and exposes the operations Slice 1 needs:

* 'appendHistory' files a batch of 'TxSummaryEntry' under their
  ordered composite keys.
* 'queryHistory' returns every entry of a single
  @(tenant, scope)@, ordered by @(slot, txid, role)@.

Two backends share the same handle and therefore the same
'appendHistory' / 'queryHistory' surface:

* 'withInMemoryHistoryIndexer' keeps a 'TVar' over a 'Map' from
  the ordered composite-key bytes ('summaryKeyToBytes') to the
  entry — ascending 'Map' key order is exactly the storage order
  and a byte-prefix range restricts the scan to one
  @(tenant, scope)@ bucket.
* 'withRocksDBHistoryIndexer' uses a @kv-transactions@ RocksDB
  'Database' keyed by the 'Cols' GADT; the same ordered key codec
  drives the on-disk byte order, so a cursor prefix-scan over
  'scopePrefix' yields the identical ordered result.

The length-prefixed variable-length parts keep strict
byte-prefix tenants/scopes (@"a"@ vs @"ab"@) from bleeding into
one another in both backends.
-}
module Cardano.Node.Client.TxHistoryIndexer.Indexer (
    -- * Indexer handle
    HistoryIndexer (..),
    withInMemoryHistoryIndexer,
    withRocksDBHistoryIndexer,

    -- * Operations
    appendHistory,
    queryHistory,
) where

import Cardano.Node.Client.TxHistoryIndexer.Columns (
    Cols (..),
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
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    nextEntry,
    seekKey,
 )
import Database.KV.Database (KV, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    RunTransaction (..),
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
in-memory and RocksDB backends provide the same two operations,
so 'appendHistory' / 'queryHistory' work uniformly across them.
-}
data HistoryIndexer = HistoryIndexer
    { hiAppend :: [TxSummaryEntry] -> IO ()
    -- ^ File a batch of entries under their ordered keys.
    , hiQuery :: TenantId -> HistoryScope -> IO [TxSummaryEntry]
    -- ^ Return every entry of @(tenant, scope)@, ordered by
    -- @(slot, txid, role)@.
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

-- In-memory backend ------------------------------------------------

{- | Open an in-memory tx-history indexer, run the action with
the handle, and discard the store on exit. The store starts
empty.
-}
withInMemoryHistoryIndexer :: (HistoryIndexer -> IO a) -> IO a
withInMemoryHistoryIndexer action = do
    store <- newTVarIO Map.empty
    action
        HistoryIndexer
            { hiAppend = memAppend store
            , hiQuery = memQuery store
            }

memAppend ::
    TVar (Map ByteString TxSummaryEntry) ->
    [TxSummaryEntry] ->
    IO ()
memAppend store entries =
    atomically $ modifyTVar' store insertAll
  where
    insertAll m = foldl insertOne m entries
    insertOne m entry =
        case summaryKeyToBytes (tseKey entry) of
            Nothing -> m
            Just k -> Map.insert k entry m

memQuery ::
    TVar (Map ByteString TxSummaryEntry) ->
    TenantId ->
    HistoryScope ->
    IO [TxSummaryEntry]
memQuery store tenant scope = do
    m <- readTVarIO store
    pure $ case scopePrefix tenant scope of
        Nothing -> []
        Just prefix ->
            [ entry
            | (k, entry) <- Map.toAscList m
            , prefix `BS.isPrefixOf` k
            ]

-- RocksDB backend --------------------------------------------------

{- | Open a RocksDB-backed tx-history indexer at @path@ (creating
the directory tree if missing) and run the action with the
handle. The on-disk store survives process restart.

One column family is created: @tx-history.entries@ — the
'HistoryCol' table. Entries are filed under the same ordered
composite key as the in-memory backend, so 'queryHistory'
returns byte-for-byte identical ordered results.
-}
withRocksDBHistoryIndexer ::
    FilePath -> (HistoryIndexer -> IO a) -> IO a
withRocksDBHistoryIndexer path action =
    withDBCF
        path
        def{createIfMissing = True}
        [("tx-history.entries", def)]
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

rocksQuery ::
    RunTransaction IO cf Cols op ->
    TenantId ->
    HistoryScope ->
    IO [TxSummaryEntry]
rocksQuery RunTransaction{runTransaction} tenant scope =
    runTransaction $
        iterating HistoryCol (scanHistory tenant scope)

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
