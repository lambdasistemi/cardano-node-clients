{- |
Module      : Cardano.Node.Client.UTxOIndexer.Indexer
Description : Address->UTxO indexer state and read API
License     : Apache-2.0

Holds the indexer's in-process state — a 'kv-transactions'
'Database' (in-memory backend in v1) keyed by the 'Cols'
GADT — and exposes the operations the rest of the daemon
needs:

* 'applyOps' commits a batch of create/spend operations
  in one transaction. Apply-block expands a chain block
  into one 'UtxoCreate' per new output and one 'UtxoSpend'
  per consumed input.
* 'snapshotAt' prefix-scans every UTxO at a given address
  using a 'Cursor'.

The op shape is asymmetric:

* 'UtxoCreate' carries the full @(TxIn, Address, TxOut)@
  triple — the producing block has all three.
* 'UtxoSpend' carries only a 'TxIn' — the consuming block
  has nothing else. The indexer's apply path resolves the
  consumed UTxO's address via 'TxInCol' before deleting
  the matching 'AddressIndex' row.

A future RocksDB swap is a one-line change:
'mkInMemoryDatabase' becomes 'mkRocksDBDatabase' from
@rocksdb-kv-transactions@; nothing else in this module
moves.

Rollback support and the @await@ STM-wakeup primitive
land in subsequent patches.
-}
module Cardano.Node.Client.UTxOIndexer.Indexer (
    -- * Indexer handle
    IndexerHandle (..),
    withInMemoryIndexer,

    -- * Operations
    UtxoOp (..),
) where

import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    TxIn (..),
    TxOut,
 )
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    nextEntry,
    seekKey,
 )
import Database.KV.Database (KV, mkColumns)
import Database.KV.InMemory (mkInMemoryDatabase)
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

{- | A single mutation against the indexer's live state.
Apply-block expands a chain block into a list of these.
-}
data UtxoOp
    = -- | Create the UTxO @(txIn, addr, txOut)@:
      -- insert into both 'TxInCol' (txIn → addr) and
      -- 'AddressIndex' ((addr, txIn) → txOut).
      UtxoCreate !TxIn !Address !TxOut
    | -- | Spend the UTxO at @txIn@: look up its address
      -- via 'TxInCol', delete from both columns. No-op if
      -- the TxIn is not in the index.
      UtxoSpend !TxIn
    deriving stock (Eq, Show)

{- | Operations the rest of the daemon performs against
the indexer state.
-}
data IndexerHandle = IndexerHandle
    { applyOps :: [UtxoOp] -> IO ()
    -- ^ Atomically apply a batch of create/spend
    -- operations against the index.
    , snapshotAt :: Address -> IO [(TxIn, TxOut)]
    -- ^ Snapshot every UTxO currently at the given
    -- address, in ascending @TxIn@ order. Used by
    -- the @utxos_at@ NDJSON request.
    }

{- | Open an in-memory indexer, run the action with the
handle, and clean up on exit.

In v1 this is the only constructor; a
'withRocksDBIndexer' variant lands when persistence is
needed without changing the @IndexerHandle@ contract or
any consumer.
-}
withInMemoryIndexer :: (IndexerHandle -> IO a) -> IO a
withInMemoryIndexer action = do
    let codecs =
            fromList
                [ TxInCol :=> txInColCodecs
                , AddressIndex :=> addressIndexCodecs
                ]
        columns = mkColumns [0 :: Int ..] codecs
    db <- mkInMemoryDatabase columns
    runner <- newRunTransaction db
    action (mkHandle runner)

-- Internal -------------------------------------------------------

type Op = (Int, BS.ByteString, Maybe BS.ByteString)

mkHandle ::
    RunTransaction IO Int Cols Op ->
    IndexerHandle
mkHandle RunTransaction{runTransaction} =
    IndexerHandle
        { applyOps = runTransaction . traverse_ applyOne
        , snapshotAt =
            runTransaction . iterating AddressIndex . scanAddress
        }

applyOne ::
    UtxoOp ->
    Transaction IO Int Cols Op ()
applyOne (UtxoCreate txIn addr txOut) = do
    insert TxInCol txIn addr
    insert AddressIndex (AddrKey addr txIn) txOut
applyOne (UtxoSpend txIn) = do
    mAddr <- query TxInCol txIn
    case mAddr of
        Nothing -> pure ()
        Just addr -> do
            delete AddressIndex (AddrKey addr txIn)
            delete TxInCol txIn

{- | Cursor program: seek to the synthetic minimum key
under @addr@ and walk forward, collecting every entry
whose key still lives under @addr@. Stops at the first
entry whose address differs (or end of column).

Each entry of 'AddressIndex' carries the 'TxOut'
inline, so no second-stage lookup is required.
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
