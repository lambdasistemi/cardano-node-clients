{- |
Module      : Cardano.Node.Client.UTxOIndexer.Columns
Description : Typed-column GADT for the indexer database
License     : Apache-2.0

Database layout for the address->UTxO indexer expressed
against the 'Database.KV.Transaction' abstraction from
@kv-transactions@.

Three columns:

* 'TxInCol' :: @KV TxIn Address@ — primary table keyed
  by the 'TxIn' alone. The chain block consuming an
  input gives us only its 'TxIn'; this column lets us
  resolve the input's address (needed to delete the
  matching 'AddressIndex' row) without scanning.
* 'AddressIndex' :: @KV AddrKey TxOut@ — secondary index
  for address-prefix snapshot queries. Composite key
  @lenByte || address || txId || ix@ so a cursor seek to
  @lenByte || address@ yields every UTxO at that address
  with its full 'TxOut' inline (no second-stage lookup).
* 'RollbackCol' :: @KV SlotNo (BlockHash, [UtxoOp])@ —
  slot-tagged inverse-op log used to undo apply-block
  writes on a chain-sync rollback. Keyed by 'SlotNo'
  (8-byte BE) so cursor ordering matches numeric slot
  ordering. The 'BlockHash' is the hash of the block
  whose application produced the inverse list — recorded
  here so a future restart-recoverability story can read
  the latest entry to derive the resume @Point@ without
  a separate tip column.

Both the in-memory and RocksDB backends share these
column definitions verbatim — the column choice happens
at the 'Database.KV.InMemory' /
'Database.KV.RocksDB' boundary, not here.
-}
module Cardano.Node.Client.UTxOIndexer.Columns (
    -- * Column GADT
    Cols (..),

    -- * Codecs
    txInColCodecs,
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,

    -- * Inverse-op list encoding
    encodeOps,
    decodeOps,
) where

import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey,
    Address (..),
    BlockHash (..),
    SlotNo,
    TxIn,
    TxOut (..),
    addrKeyFromBytes,
    addrKeyToBytes,
    slotFromBytes,
    slotToBytes,
    txInFromBytes,
    txInToBytes,
 )
import Control.Lens (Prism', prism')
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.GADT.Compare (
    GCompare (..),
    GEq (..),
    GOrdering (..),
 )
import Data.Type.Equality (type (:~:) (Refl))
import Data.Word (Word32)
import Database.KV.Transaction (Codecs (..), KV)

-- | The indexer database's column families.
data Cols c where
    -- | Primary table: @TxIn → Address@. Lets the
    -- spend-by-TxIn path resolve the consumed UTxO's
    -- address without scanning. Key is 34 bytes fixed.
    TxInCol :: Cols (KV TxIn Address)
    -- | Secondary index: @AddrKey → TxOut@ where
    -- @AddrKey = (Address, TxIn)@ is encoded as
    -- @lenByte || address || txId || ix@. Cursor
    -- prefix-scan by address yields @(TxIn, TxOut)@
    -- pairs directly.
    AddressIndex :: Cols (KV AddrKey TxOut)
    -- | Rollback log: 'SlotNo' →
    -- @('BlockHash', [inverse ops])@. The list is in the
    -- order to apply on rollback (i.e. already reversed
    -- relative to the original apply order). The
    -- 'BlockHash' is the hash of the block that produced
    -- this entry — recorded so a future startup can
    -- recover the resume @Point@ from the latest entry.
    RollbackCol :: Cols (KV SlotNo (BlockHash, [UtxoOp]))
    -- | Observation index: every live (i.e. created and
    -- not yet spent) 'TxIn' carries the @('SlotNo',
    -- 'BlockHash')@ of the block that created it. Used
    -- by 'awaitTxIn' to answer "has this TxIn been
    -- observed?" across process restart — the in-process
    -- @Observed@ TVar is empty after reopen, but this
    -- column persists, so the fast path reconstructs
    -- the observation from on-disk state.
    ObservationCol :: Cols (KV TxIn (SlotNo, BlockHash))

instance GEq Cols where
    geq TxInCol TxInCol = Just Refl
    geq AddressIndex AddressIndex = Just Refl
    geq RollbackCol RollbackCol = Just Refl
    geq ObservationCol ObservationCol = Just Refl
    geq _ _ = Nothing

instance GCompare Cols where
    gcompare TxInCol TxInCol = GEQ
    gcompare TxInCol _ = GLT
    gcompare _ TxInCol = GGT
    gcompare AddressIndex AddressIndex = GEQ
    gcompare AddressIndex _ = GLT
    gcompare _ AddressIndex = GGT
    gcompare ObservationCol ObservationCol = GEQ
    gcompare ObservationCol RollbackCol = GLT
    gcompare RollbackCol ObservationCol = GGT
    gcompare RollbackCol RollbackCol = GEQ

-- | Codecs for 'TxInCol'.
txInColCodecs :: Codecs (KV TxIn Address)
txInColCodecs =
    Codecs
        { keyCodec = txInPrism
        , valueCodec = addressPrism
        }

-- | Codecs for 'AddressIndex'.
addressIndexCodecs :: Codecs (KV AddrKey TxOut)
addressIndexCodecs =
    Codecs
        { keyCodec = addrKeyPrism
        , valueCodec = txOutPrism
        }

{- | Codecs for the observation column. The value is
@slotBytes(8 BE) || blockHashLen(4 BE) || blockHash@.
-}
observationColCodecs ::
    Codecs (KV TxIn (SlotNo, BlockHash))
observationColCodecs =
    Codecs
        { keyCodec = txInPrism
        , valueCodec = observationPrism
        }

{- | Codecs for the rollback-log column. The on-disk
value is @blockHashLen(4 BE) || blockHash || ops@ where
@ops@ uses the stable hand-rolled form (see 'encodeOps')
so a future RocksDB swap can read entries written by the
in-memory backend.
-}
rollbackCodecs :: Codecs (KV SlotNo (BlockHash, [UtxoOp]))
rollbackCodecs =
    Codecs
        { keyCodec = slotPrism
        , valueCodec = rollbackEntryPrism
        }

-- Internal --------------------------------------------------------

txInPrism :: Prism' ByteString TxIn
txInPrism = prism' txInToBytes txInFromBytes

addressPrism :: Prism' ByteString Address
addressPrism = prism' unAddress (Just . Address)

addrKeyPrism :: Prism' ByteString AddrKey
addrKeyPrism =
    -- Encoding any address shorter than 256 bytes always
    -- succeeds; we 'error' on the impossible case rather
    -- than thread 'Maybe' through every caller (real
    -- ledger never produces such addresses).
    prism' encode addrKeyFromBytes
  where
    encode k = case addrKeyToBytes k of
        Just bs -> bs
        Nothing ->
            error
                "addrKeyPrism: address exceeds 255 bytes — \
                \invariant violation, ledger never produces \
                \such addresses"

txOutPrism :: Prism' ByteString TxOut
txOutPrism = prism' unTxOut (Just . TxOut)

slotPrism :: Prism' ByteString SlotNo
slotPrism = prism' slotToBytes slotFromBytes

{- | Codec for the @(BlockHash, [UtxoOp])@ rollback
entry: @blockHashLen(4 BE) || blockHash || encodeOps@.
-}
rollbackEntryPrism :: Prism' ByteString (BlockHash, [UtxoOp])
rollbackEntryPrism = prism' encode decode
  where
    encode (BlockHash bh, ops) =
        lenPrefixed bh <> encodeOps ops
    decode bs0 = do
        (bhBs, rest) <- readLenPrefixed bs0
        ops <- decodeOps rest
        Just (BlockHash bhBs, ops)

{- | Codec for the @('SlotNo', 'BlockHash')@ observation
entry: @slotBytes(8 BE) || blockHashLen(4 BE) || blockHash@.
-}
observationPrism :: Prism' ByteString (SlotNo, BlockHash)
observationPrism = prism' encode decode
  where
    encode (slot, BlockHash bh) =
        slotToBytes slot <> lenPrefixed bh
    decode bs0 = do
        (slotBs, rest0) <- splitFixed 8 bs0
        slot <- slotFromBytes slotBs
        (bhBs, rest1) <- readLenPrefixed rest0
        if BS.null rest1
            then Just (slot, BlockHash bhBs)
            else Nothing

-- Inverse-op list binary encoding ---------------------------------
--
-- @
-- list   = listLen ++ encodedOps
-- create = 0 ++ txIn(34) ++ addrLen(4 BE) ++ addr ++ txOutLen(4 BE) ++ txOut
-- spend  = 1 ++ txIn(34)
-- @

{- | Encode a list of 'UtxoOp' into the rollback-column's
on-disk byte form.
-}
encodeOps :: [UtxoOp] -> ByteString
encodeOps ops =
    word32BE (fromIntegral (length ops))
        <> mconcat (map encodeOp ops)

encodeOp :: UtxoOp -> ByteString
encodeOp (UtxoCreate txIn (Address addr) (TxOut txOut)) =
    BS.singleton 0
        <> txInToBytes txIn
        <> lenPrefixed addr
        <> lenPrefixed txOut
encodeOp (UtxoSpend txIn) =
    BS.singleton 1 <> txInToBytes txIn

lenPrefixed :: ByteString -> ByteString
lenPrefixed bs = word32BE (fromIntegral (BS.length bs)) <> bs

{- | Inverse of 'encodeOps'. Returns 'Nothing' if the
byte string is malformed.
-}
decodeOps :: ByteString -> Maybe [UtxoOp]
decodeOps bs0 = do
    (n, rest0) <- readWord32 bs0
    (ops, rest1) <- readN (fromIntegral n) decodeOp rest0
    if BS.null rest1
        then Just ops
        else Nothing

decodeOp :: ByteString -> Maybe (UtxoOp, ByteString)
decodeOp bs0 = do
    (tag, rest0) <- BS.uncons bs0
    case tag of
        0 -> do
            (txInBs, rest1) <- splitFixed 34 rest0
            txIn <- txInFromBytes txInBs
            (addrBs, rest2) <- readLenPrefixed rest1
            (txOutBs, rest3) <- readLenPrefixed rest2
            Just
                ( UtxoCreate
                    txIn
                    (Address addrBs)
                    (TxOut txOutBs)
                , rest3
                )
        1 -> do
            (txInBs, rest1) <- splitFixed 34 rest0
            txIn <- txInFromBytes txInBs
            Just (UtxoSpend txIn, rest1)
        _ -> Nothing

splitFixed :: Int -> ByteString -> Maybe (ByteString, ByteString)
splitFixed n bs
    | BS.length bs < n = Nothing
    | otherwise = Just (BS.splitAt n bs)

readLenPrefixed :: ByteString -> Maybe (ByteString, ByteString)
readLenPrefixed bs0 = do
    (n, rest0) <- readWord32 bs0
    let len = fromIntegral n
    if BS.length rest0 < len
        then Nothing
        else Just (BS.splitAt len rest0)

readWord32 :: ByteString -> Maybe (Word32, ByteString)
readWord32 bs
    | BS.length bs < 4 = Nothing
    | otherwise =
        let (hd, tl) = BS.splitAt 4 bs
            w =
                foldr (.|.) 0 $
                    zipWith
                        (\s b -> fromIntegral b `shiftL` s)
                        [24 :: Int, 16, 8, 0]
                        (BS.unpack hd)
         in Just (w, tl)

readN ::
    Int ->
    (ByteString -> Maybe (a, ByteString)) ->
    ByteString ->
    Maybe ([a], ByteString)
readN 0 _ bs = Just ([], bs)
readN n step bs = do
    (a, bs') <- step bs
    (as, bs'') <- readN (n - 1) step bs'
    Just (a : as, bs'')

word32BE :: Word32 -> ByteString
word32BE w =
    BS.pack
        [ fromIntegral (w `shiftR` 24) .&. 0xFF
        , fromIntegral (w `shiftR` 16) .&. 0xFF
        , fromIntegral (w `shiftR` 8) .&. 0xFF
        , fromIntegral w .&. 0xFF
        ]
