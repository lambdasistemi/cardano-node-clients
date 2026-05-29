{- |
Module      : Cardano.Node.Client.UTxOIndexer.BlockExtract
Description : Extract @(SlotNo, [UtxoOp])@ from a Cardano consensus block
License     : Apache-2.0

Era-polymorphic block decoding using @cardano-ledger-read@'s
'Cardano.Read.Ledger' helpers — the same abstraction
'cardano-utxo-csmt' uses. Each block is mapped through
'fromConsensusBlock' into an era-tagged value; the
extraction logic is then expressed once over an
@IsEra era@ constraint and run via 'applyEraFun'.

This sidesteps the renames the raw @cardano-ledger-api@
goes through (e.g. @SafeHash@ → @Hashes@,
@Cardano.Ledger.Shelley.BlockChain@ →
@Cardano.Ledger.Shelley.BlockBody@, @txid@ → @txIdTx@,
@Tx era@ → @Tx l era@, @TxId c@ → @TxId@) — they all
live below 'cardano-ledger-read''s API surface.
-}
module Cardano.Node.Client.UTxOIndexer.BlockExtract (
    extractBlock,
    extractBlockTxs,
) where

import Cardano.Chain.Common (unsafeGetLovelace)
import Cardano.Chain.UTxO qualified as ByronUTxO
import Cardano.Crypto.Hash.Class (Hash (..), hashToBytes)
import Cardano.Crypto.Hashing (abstractHashToShort)
import Cardano.Ledger.Address (
    Addr (..),
    BootstrapAddress (..),
    serialiseAddr,
 )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (
    EraTx,
    EraTxBody,
    EraTxOut,
    TopTx,
    addrTxOutL,
    bodyTxL,
    eraProtVerLow,
    inputsTxBodyL,
    outputsTxBodyL,
    txIdTxBody,
 )
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.TxIn qualified as SH
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.TxHistoryIndexer.BlockExtract (
    BlockTx,
    mkBlockTx,
 )
import Cardano.Node.Client.Types (Block)
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Read.Ledger.Block.Block (fromConsensusBlock)
import Cardano.Read.Ledger.Block.Txs (getEraTransactions)
import Cardano.Read.Ledger.Eras.EraValue (applyEraFun)
import Cardano.Read.Ledger.Eras.KnownEras (
    Byron,
    Era (..),
    IsEra,
    theEra,
 )

-- Era pattern aliases are exported via 'Era (..)' above; the
-- 'Dijkstra' case in 'changes' below requires this re-export
-- pattern match to be exhaustive.
import Cardano.Read.Ledger.Tx.Inputs (Inputs (..), getEraInputs)
import Cardano.Read.Ledger.Tx.Outputs (Outputs (..), getEraOutputs)
import Cardano.Read.Ledger.Tx.Tx (Tx (..))
import Cardano.Read.Ledger.Tx.TxId (TxId (..), getEraTxId)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Word (Word16)
import Lens.Micro ((^.))
import Ouroboros.Consensus.Cardano.Node ()
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Point qualified as Network.Point

{- | Extract @(slot, ops)@ from a Cardano consensus block.

The slot comes from the block header; the ops list is
the concatenation, in transaction order, of each tx's
spends followed by its creates.
-}
extractBlock :: Block -> (SlotNo, [UtxoOp])
extractBlock blk =
    ( blockSlot blk
    , applyEraFun (changes . getEraTransactions) (fromConsensusBlock blk)
    )

{- | Extract the raw, treasury-neutral per-transaction payloads
('BlockTx') from a Cardano consensus block, in transaction order.

Each Shelley-family transaction is re-serialised to its on-chain
CBOR bytes and wrapped in a 'BlockTx'; this library attaches no
meaning to those bytes — a downstream
'Cardano.Node.Client.TxHistoryIndexer.BlockExtract.DecodeTx' owns all
interpretation. Byron transactions carry no treasury history and are
skipped (history indexing targets the Shelley-and-later eras).
-}
extractBlockTxs :: Block -> [BlockTx]
extractBlockTxs blk =
    applyEraFun (blockTxs . getEraTransactions) (fromConsensusBlock blk)

{- | Per-era serialisation of a transaction list into 'BlockTx'
payloads. Byron yields none; every Shelley-family era re-serialises
each transaction to its CBOR bytes.
-}
blockTxs :: forall era. (IsEra era) => [Tx era] -> [BlockTx]
blockTxs txs = case theEra @era of
    Byron -> []
    Shelley -> shelleyBlockTxs (unTx <$> txs)
    Allegra -> shelleyBlockTxs (unTx <$> txs)
    Mary -> shelleyBlockTxs (unTx <$> txs)
    Alonzo -> shelleyBlockTxs (unTx <$> txs)
    Babbage -> shelleyBlockTxs (unTx <$> txs)
    Conway -> shelleyBlockTxs (unTx <$> txs)
    Dijkstra -> shelleyBlockTxs (unTx <$> txs)

{- | Re-serialise each Shelley-family transaction to its CBOR bytes
and wrap it as a 'BlockTx'. Takes the ledger transaction directly (the
per-era @TxT era ~ Core.Tx era@ refinement is applied at the call
site), so the 'EraTx' superclass @EncCBOR (Tx era)@ supplies the
encoder.
-}
shelleyBlockTxs ::
    forall era.
    (EraTx era) =>
    [Ledger.Tx TopTx era] ->
    [BlockTx]
shelleyBlockTxs =
    fmap (mkBlockTx . serialize' (eraProtVerLow @era))

{- | Slot of the block. Cardano blocks are non-genesis;
the @Origin@ case is structurally impossible here so
we map it to slot 0 (defensive).
-}
blockSlot :: Block -> SlotNo
blockSlot blk =
    case Network.pointSlot (Network.blockPoint blk) of
        Network.Point.Origin -> SlotNo 0
        Network.Point.At s -> SlotNo (Network.unSlotNo s)

{- | UTxO ops produced by a single era's tx list. Each
Shelley-family branch narrows
@TxT era ~ Core.Tx Core.TopTx era@ so the
@bodyTxL@/@inputsTxBodyL@/@outputsTxBodyL@ lenses
become applicable.
-}
changes :: forall era. (IsEra era) => [Tx era] -> [UtxoOp]
changes txs = case theEra @era of
    Byron -> concatMap byronTxChanges txs
    Shelley -> concatMap (shelleyTxChanges . unTx) txs
    Allegra -> concatMap (shelleyTxChanges . unTx) txs
    Mary -> concatMap (shelleyTxChanges . unTx) txs
    Alonzo -> concatMap (shelleyTxChanges . unTx) txs
    Babbage -> concatMap (shelleyTxChanges . unTx) txs
    Conway -> concatMap (shelleyTxChanges . unTx) txs
    Dijkstra -> concatMap (shelleyTxChanges . unTx) txs

{- | Convert a Byron transaction into @UtxoOp@s.

Byron tx ids are raw Blake2b_256 hashes wrapped by
@cardano-chain@. We re-wrap them as Shelley 'SH.TxId'
only to reuse the same 32-byte storage representation as
Shelley-family inputs and created outputs.
-}
byronTxChanges :: Tx Byron -> [UtxoOp]
byronTxChanges tx =
    let tid = byronTxIdBytes (unTxId (getEraTxId tx))
        Inputs ins = getEraInputs tx
        Outputs outs = getEraOutputs tx
        spends = UtxoSpend . byronTxInToIndexer <$> toList ins
        creates =
            zipWith
                (mkByronCreate tid)
                [0 ..]
                (toList outs)
     in spends <> creates

{- | Convert a Shelley-family @'Core.Tx' TopTx era@ into a
list of @UtxoOp@s.
-}
shelleyTxChanges ::
    forall era.
    (EraTx era) =>
    Ledger.Tx TopTx era ->
    [UtxoOp]
shelleyTxChanges tx =
    let body = tx ^. bodyTxL
        tid = txBodyIdBytes @era body
        ins = body ^. inputsTxBodyL
        outs = body ^. outputsTxBodyL
        spends = UtxoSpend . shelleyTxInToIndexer <$> toList ins
        creates =
            zipWith
                (mkCreate @era tid)
                [0 ..]
                (toList outs)
     in spends <> creates

{- | Bytes of the Shelley-family TxBody's hash (used as
@txInId@ for outputs created by this body).
-}
txBodyIdBytes ::
    forall era. (EraTxBody era) => Ledger.TxBody TopTx era -> ByteString
txBodyIdBytes body =
    shelleyTxIdBytes (txIdTxBody body)

byronTxIdBytes :: ByronUTxO.TxId -> ByteString
byronTxIdBytes = shelleyTxIdBytes . byronTxIdToShelley

shelleyTxIdBytes :: SH.TxId -> ByteString
shelleyTxIdBytes (SH.TxId safeHash) =
    hashToBytes (extractHash safeHash)

shelleyTxInToIndexer :: SH.TxIn -> TxIn
shelleyTxInToIndexer (SH.TxIn txId (TxIx ix)) =
    TxIn
        { txInId = shelleyTxIdBytes txId
        , txInIx = fromIntegral ix
        }

byronTxInToIndexer :: ByronUTxO.TxIn -> TxIn
byronTxInToIndexer (ByronUTxO.TxInUtxo txId ix) =
    TxIn
        { txInId = byronTxIdBytes txId
        , txInIx = ix
        }

mkCreate ::
    forall era.
    (EraTxOut era) =>
    -- | producing tx id (32 raw bytes)
    ByteString ->
    -- | output index
    Word16 ->
    Ledger.TxOut era ->
    UtxoOp
mkCreate tid ix out =
    UtxoCreate
        TxIn{txInId = tid, txInIx = ix}
        (Address (serialiseAddr (out ^. addrTxOutL)))
        (TxOut (serialize' (eraProtVerLow @era) out))

mkByronCreate ::
    -- | producing tx id (32 raw bytes)
    ByteString ->
    -- | output index
    Word16 ->
    ByronUTxO.TxOut ->
    UtxoOp
mkByronCreate tid ix out =
    UtxoCreate
        TxIn{txInId = tid, txInIx = ix}
        (byronTxOutAddress out)
        ( TxOut
            ( serialize'
                (eraProtVerLow @ConwayEra)
                (fromByronOutput out)
            )
        )

byronTxOutAddress :: ByronUTxO.TxOut -> Address
byronTxOutAddress (ByronUTxO.TxOut addr _lovelace) =
    Address (serialiseAddr (AddrBootstrap (BootstrapAddress addr)))

{- | Convert a Byron 'ByronUTxO.TxOut' to the Conway-era
@TxOut@ shape consumed by downstream indexer readers.
-}
fromByronOutput :: ByronUTxO.TxOut -> Ledger.TxOut ConwayEra
fromByronOutput (ByronUTxO.TxOut addr lovelace) =
    mkBasicTxOut @ConwayEra
        (AddrBootstrap (BootstrapAddress addr))
        (inject $ Coin $ toInteger $ unsafeGetLovelace lovelace)

{- | Convert a Byron TxId to a Shelley TxId.

This mirrors cardano-utxo-csmt: extract the underlying
32-byte Blake2b_256 hash and re-wrap it as a Shelley safe
hash so both eras feed the indexer the same tx-id bytes.
-}
byronTxIdToShelley :: ByronUTxO.TxId -> SH.TxId
byronTxIdToShelley =
    SH.TxId . unsafeMakeSafeHash . UnsafeHash . abstractHashToShort
