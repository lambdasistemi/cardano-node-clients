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

Byron support is stubbed (returns @[]@). Devnet
workloads post-date the Byron→Shelley hard fork; if a
consumer ever needs Byron data, the stub is the obvious
place to wire it in.
-}
module Cardano.Node.Client.UTxOIndexer.BlockExtract (
    extractBlock,
) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
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
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn qualified as SH
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
    Era (..),
    IsEra,
    theEra,
 )

-- Era pattern aliases are exported via 'Era (..)' above; the
-- 'Dijkstra' case in 'changes' below requires this re-export
-- pattern match to be exhaustive.
import Cardano.Read.Ledger.Tx.Tx (Tx (..))
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

{- | Slot of the block. Cardano blocks are non-genesis;
the @Origin@ case is structurally impossible here so
we map it to slot 0 (defensive).
-}
blockSlot :: Block -> SlotNo
blockSlot blk =
    case Network.pointSlot (Network.blockPoint blk) of
        Network.Point.Origin -> SlotNo 0
        Network.Point.At s -> SlotNo (Network.unSlotNo s)

{- | UTxO ops produced by a single era's tx list. Byron
returns @[]@ — pre-Shelley blocks are not exercised by
current workloads. Each Shelley-family branch narrows
@TxT era ~ Core.Tx Core.TopTx era@ so the
@bodyTxL@/@inputsTxBodyL@/@outputsTxBodyL@ lenses
become applicable.
-}
changes :: forall era. (IsEra era) => [Tx era] -> [UtxoOp]
changes txs = case theEra @era of
    Byron -> []
    Shelley -> concatMap (shelleyTxChanges . unTx) txs
    Allegra -> concatMap (shelleyTxChanges . unTx) txs
    Mary -> concatMap (shelleyTxChanges . unTx) txs
    Alonzo -> concatMap (shelleyTxChanges . unTx) txs
    Babbage -> concatMap (shelleyTxChanges . unTx) txs
    Conway -> concatMap (shelleyTxChanges . unTx) txs
    Dijkstra -> concatMap (shelleyTxChanges . unTx) txs

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
    case txIdTxBody body of
        SH.TxId safeHash -> hashToBytes (extractHash safeHash)

shelleyTxInToIndexer :: SH.TxIn -> TxIn
shelleyTxInToIndexer (SH.TxIn (SH.TxId safeHash) (TxIx ix)) =
    TxIn
        { txInId = hashToBytes (extractHash safeHash)
        , txInIx = fromIntegral ix
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
