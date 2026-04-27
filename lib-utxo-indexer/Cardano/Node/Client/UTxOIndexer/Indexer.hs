{- |
Module      : Cardano.Node.Client.UTxOIndexer.Indexer
Description : Address->UTxO indexer state and read API
License     : Apache-2.0

Holds the indexer's in-process state — a 'kv-transactions'
'Database' (in-memory backend in v1) keyed by the 'Cols'
GADT — and exposes the operations the rest of the daemon
needs:

* 'applyAtSlot' commits a batch of create/spend operations
  in one transaction, and atomically records the inverse
  list under that slot in the rollback column.
* 'rollbackTo' replays the inverse-op log for every slot
  strictly greater than the target, in descending slot
  order, then deletes those entries.
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

The @await@ STM-wakeup primitive lands in a subsequent
patch.
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
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    SlotNo,
    TxIn (..),
    TxOut,
 )
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    lastEntry,
    nextEntry,
    prevEntry,
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

{- | Operations the rest of the daemon performs against
the indexer state.
-}
data IndexerHandle = IndexerHandle
    { applyAtSlot :: SlotNo -> [UtxoOp] -> IO ()
    -- ^ Atomically apply a batch of create/spend
    -- operations and store the inverse list under the
    -- given slot in 'RollbackCol'. Used by the
    -- chain-sync follower's apply-block path.
    , rollbackTo :: SlotNo -> IO ()
    -- ^ Roll the index back to the given slot by
    -- replaying inverse-op lists for every slot
    -- @> target@, in descending slot order, then
    -- deleting those rollback entries. Used by the
    -- chain-sync follower's roll-backward path.
    , snapshotAt :: Address -> IO [(TxIn, TxOut)]
    -- ^ Snapshot every UTxO currently at the given
    -- address, in ascending @TxIn@ order. Used by
    -- the @utxos_at@ NDJSON request.
    }

{- | Open an in-memory indexer, run the action with the
handle, and clean up on exit.
-}
withInMemoryIndexer :: (IndexerHandle -> IO a) -> IO a
withInMemoryIndexer action = do
    let codecs =
            fromList
                [ TxInCol :=> txInColCodecs
                , AddressIndex :=> addressIndexCodecs
                , RollbackCol :=> rollbackCodecs
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
        { applyAtSlot = \slot ops ->
            runTransaction (applyAndLog slot ops)
        , rollbackTo = runTransaction . rollbackToSlot
        , snapshotAt =
            runTransaction . iterating AddressIndex . scanAddress
        }

{- | Within one transaction: for each op compute its
inverse against the current state, apply the op, and
finally store the reversed list of inverses under
@slot@ in 'RollbackCol'.

Computing the inverse before applying is essential —
@query@ inside the same transaction sees buffered
writes (read-your-writes), so once an op is applied,
its inverse cannot be recovered from a later @query@.
-}
applyAndLog ::
    SlotNo ->
    [UtxoOp] ->
    Transaction IO Int Cols Op ()
applyAndLog slot ops = do
    inverses <- traverse step ops
    insert RollbackCol slot (reverse inverses)
  where
    step op = do
        inv <- inverseOf op
        applyOne op
        pure inv

{- | Roll back every slot strictly greater than
@target@. Walks 'RollbackCol' from the highest slot
down via 'lastEntry'/'prevEntry', collecting entries
@> target@, then in a second pass replays each
inverse-op list and deletes the corresponding rollback
entry — both inside the same transaction.

Two passes are needed because applying inverses (which
@insert@/@delete@ into the workspace) does not affect
the live cursor: the cursor reads from a snapshot of
the underlying column. Collecting first guarantees we
do not skip entries when later steps mutate the
column.
-}
rollbackToSlot ::
    SlotNo ->
    Transaction IO Int Cols Op ()
rollbackToSlot target = do
    entries <-
        iterating RollbackCol $
            collectGreaterThan target
    traverse_ undoSlot entries
  where
    undoSlot (slot, invs) = do
        traverse_ applyOne invs
        delete RollbackCol slot

{- | Cursor program: from 'lastEntry' walk backwards,
collecting @(slot, invs)@ pairs while @slot > target@.
Returns them in descending-slot order.
-}
collectGreaterThan ::
    (Monad m) =>
    SlotNo ->
    Cursor m (KV SlotNo [UtxoOp]) [(SlotNo, [UtxoOp])]
collectGreaterThan target =
    lastEntry >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = slot, entryValue = invs})
        | slot > target =
            prevEntry >>= go ((slot, invs) : acc)
        | otherwise = pure (reverse acc)

{- | Inverse of a single op against current state.

* @inv (UtxoCreate txIn _a _v)@: query 'TxInCol' for
  @txIn@. If present (with @a_old@), query
  'AddressIndex' for @(a_old, txIn)@'s @v_old@; the
  inverse is @UtxoCreate txIn a_old v_old@. If absent,
  the inverse is @UtxoSpend txIn@.
* @inv (UtxoSpend txIn)@: same shape — query current
  state, restore via @UtxoCreate@; if absent the spend
  was a no-op so the inverse is too.
-}
inverseOf ::
    UtxoOp ->
    Transaction IO Int Cols Op UtxoOp
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
