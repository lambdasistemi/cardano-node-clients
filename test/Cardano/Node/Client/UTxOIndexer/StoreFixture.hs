{- |
Module      : Cardano.Node.Client.UTxOIndexer.StoreFixture
Description : Store contents and pre-change stores for store-level specs
License     : Apache-2.0

Reads a store's whole contents, open (every typed column) or closed
(the raw bytes of every column family), so a spec can state that an
operation left the store untouched. Writes a directory with only the
four column families that existed before the asset index, as the
pre-change binary would have.
-}
module Cardano.Node.Client.UTxOIndexer.StoreFixture (
    -- * Contents
    dumpStore,
    dumpClosedStore,

    -- * Pre-change stores
    seedPreChangeStore,
    storeFamilyCount,
) where

import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address,
    BlockHash,
    SlotNo,
    TxIn,
    TxOut,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Default.Class (def)
import Database.KV.Cursor (Cursor, Entry (..), firstEntry, nextEntry)
import Database.KV.Database (Codecs, KV, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    DMap,
    DSum ((:=>)),
    RunTransaction (..),
    Transaction,
    fromList,
    insert,
    iterating,
    newRunTransaction,
 )
import Database.RocksDB (
    Config (..),
    columnFamilies,
    iterEntry,
    iterFirst,
    iterNext,
    iterValid,
    withDBCF,
    withIterCF,
 )

{- | Every entry of every typed column of an open store, shown, column
by column. Equal dumps mean equal contents.
-}
dumpStore :: RunTransaction IO cf Cols op -> IO [[String]]
dumpStore runner =
    runTransaction runner $
        sequence
            [ dumpColumn TxInCol
            , dumpColumn AddressIndex
            , dumpColumn ObservationCol
            , dumpColumn RollbackCol
            , dumpColumn AssetIndex
            , dumpColumn MetaCol
            ]

dumpColumn ::
    forall k v cf op.
    (Show k, Show v) =>
    Cols (KV k v) ->
    Transaction IO cf Cols op [String]
dumpColumn col = iterating col (firstEntry >>= go)
  where
    go ::
        Maybe (Entry (KV k v)) ->
        Cursor (Transaction IO cf Cols op) (KV k v) [String]
    go Nothing = pure []
    go (Just Entry{entryKey, entryValue}) =
        (show (entryKey, entryValue) :) <$> (nextEntry >>= go)

{- | The raw key/value bytes of every column family of a closed store,
opened with the family list it has (four, five or six).
-}
dumpClosedStore :: FilePath -> IO [[(ByteString, ByteString)]]
dumpClosedStore path = do
    n <- storeFamilyCount path
    withDBCF path def (take n fullFamilies) $ \rdb ->
        forM (columnFamilies rdb) $ \cf ->
            withIterCF rdb cf $ \iter -> iterFirst iter >> collect iter
  where
    collect iter = do
        valid <- iterValid iter
        if not valid
            then pure []
            else do
                e <- iterEntry iter
                iterNext iter
                maybe id (:) e <$> collect iter

{- | How many of the six families, in order, a closed store has: the
only prefix of the list it opens with (RocksDB refuses an open that
omits an existing family or names a missing one).
-}
storeFamilyCount :: FilePath -> IO Int
storeFamilyCount path = go [6, 5, 4]
  where
    go [] = fail "the store opens with no prefix of the six families"
    go (n : rest) = do
        r <- try @IOException (withDBCF path def (take n fullFamilies) (\_ -> pure n))
        either (const (go rest)) pure r

{- | A new directory with only the four pre-change families, holding
the given live outputs (each with its observation) and one rollback
row per given block.
-}
seedPreChangeStore ::
    FilePath ->
    [(TxIn, Address, TxOut, (SlotNo, BlockHash))] ->
    [(SlotNo, BlockHash)] ->
    IO ()
seedPreChangeStore path outputs blocks =
    withDBCF path def{createIfMissing = True} (take 4 fullFamilies) $ \rdb -> do
        runner <-
            newRunTransaction
                (mkRocksDBDatabase rdb (mkColumns (columnFamilies rdb) preChangeCodecs))
        runTransaction runner $ do
            forM_ outputs $ \(txIn, addr, out, created) -> do
                insert TxInCol txIn addr
                insert AddressIndex (AddrKey addr txIn) out
                insert ObservationCol txIn created
            forM_ blocks $ \(slot, hash) ->
                insert
                    RollbackCol
                    slot
                    RollbackPoint{rpInverses = [[]], rpMeta = Just hash}

preChangeCodecs :: DMap Cols Codecs
preChangeCodecs =
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
