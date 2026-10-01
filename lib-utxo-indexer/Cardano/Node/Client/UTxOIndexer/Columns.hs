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
* 'RollbackCol' :: @KV SlotNo ('RollbackPoint' ['UtxoOp']
  'BlockHash')@ — slot-tagged inverse-op log used to
  undo apply-block writes on a chain-sync rollback.
  Keyed by 'SlotNo' (8-byte BE) so cursor ordering
  matches numeric slot ordering. The value uses
  @chain-follower@'s canonical 'RollbackPoint' shape —
  @rpInverses@ holds block-level inverse batches. Normal
  following rows keep one batch plus the block hash in
  @rpMeta@ so a startup can derive resume @Point@s;
  restoration rows are sentinels with @rpInverses = []@
  and @rpMeta = Nothing@.

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
    assetIndexCodecs,
    metaCodecs,

    -- * Inverse-op list encoding
    encodeOps,
    decodeOps,
) where

import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey,
    Address (..),
    AssetKey,
    BlockHash (..),
    SlotNo,
    TxIn,
    TxOut (..),
    addrKeyFromBytes,
    addrKeyToBytes,
    assetKeyFromBytes,
    assetKeyToBytes,
    slotFromBytes,
    slotToBytes,
    txInFromBytes,
    txInToBytes,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
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
import Data.Word (Word32, Word64)
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
    -- @'RollbackPoint' ['UtxoOp'] 'BlockHash'@. Uses
    -- @chain-follower@'s canonical shape: @rpInverses@
    -- stores block-level inverse batches (each already in
    -- apply order on rollback). Following rows keep one
    -- batch plus the block hash in @rpMeta@; restoration
    -- rows are sentinels with @rpMeta = Nothing@.
    RollbackCol :: Cols (KV SlotNo (RollbackPoint [UtxoOp] BlockHash))
    -- | Observation index: every live (i.e. created and
    -- not yet spent) 'TxIn' carries the @('SlotNo',
    -- 'BlockHash')@ of the block that created it. Used
    -- by 'awaitTxIn' to answer "has this TxIn been
    -- observed?" across process restart — the in-process
    -- @Observed@ TVar is empty after reopen, but this
    -- column persists, so the fast path reconstructs
    -- the observation from on-disk state.
    ObservationCol :: Cols (KV TxIn (SlotNo, BlockHash))
    -- | Asset index: one row per (policy id, asset name,
    -- holding 'TxIn') with the positive quantity. Written and
    -- deleted by re-extracting the live output's stored bytes,
    -- so the rows are always exactly the multi-asset entries of
    -- the live outputs.
    AssetIndex :: Cols (KV AssetKey Word64)
    -- | Store metadata. v1 holds the single key
    -- @asset-index@ marking a store whose asset index is
    -- complete since creation.
    MetaCol :: Cols (KV ByteString ByteString)

instance GEq Cols where
    geq TxInCol TxInCol = Just Refl
    geq AddressIndex AddressIndex = Just Refl
    geq RollbackCol RollbackCol = Just Refl
    geq ObservationCol ObservationCol = Just Refl
    geq AssetIndex AssetIndex = Just Refl
    geq MetaCol MetaCol = Just Refl
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
    gcompare ObservationCol AssetIndex = GLT
    gcompare ObservationCol MetaCol = GLT
    gcompare RollbackCol ObservationCol = GGT
    gcompare RollbackCol RollbackCol = GEQ
    gcompare RollbackCol AssetIndex = GLT
    gcompare RollbackCol MetaCol = GLT
    gcompare AssetIndex ObservationCol = GGT
    gcompare AssetIndex RollbackCol = GGT
    gcompare AssetIndex AssetIndex = GEQ
    gcompare AssetIndex MetaCol = GLT
    gcompare MetaCol ObservationCol = GGT
    gcompare MetaCol RollbackCol = GGT
    gcompare MetaCol AssetIndex = GGT
    gcompare MetaCol MetaCol = GEQ

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

{- | Codecs for the rollback-log column. Following rows use
@blockHashLen(4 BE) || blockHash || ops@ where @ops@ uses
the stable hand-rolled form (see 'encodeOps'). Restoration
sentinels use @0xffffffff || ops@, with @ops@ normally
empty. Decoded into @chain-follower@'s 'RollbackPoint'
shape so the @Rollbacks.*@ library functions accept it
directly.
-}
rollbackCodecs ::
    Codecs (KV SlotNo (RollbackPoint [UtxoOp] BlockHash))
rollbackCodecs =
    Codecs
        { keyCodec = slotPrism
        , valueCodec = rollbackEntryPrism
        }

{- | Codecs for the asset index. Keys are the composite asset
key (see 'assetKeyToBytes'); values are 8-byte big-endian
quantities.
-}
assetIndexCodecs :: Codecs (KV AssetKey Word64)
assetIndexCodecs =
    Codecs
        { keyCodec = assetKeyPrism
        , valueCodec = quantityPrism
        }

-- | Codecs for the metadata column: raw bytes both ways.
metaCodecs :: Codecs (KV ByteString ByteString)
metaCodecs =
    Codecs
        { keyCodec = prism' id Just
        , valueCodec = prism' id Just
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

assetKeyPrism :: Prism' ByteString AssetKey
assetKeyPrism = prism' assetKeyToBytes assetKeyFromBytes

quantityPrism :: Prism' ByteString Word64
quantityPrism = prism' word64BE word64FromBE

{- | Codec for the rollback entry. On-disk shape stays
@blockHashLen(4 BE) || blockHash || encodeOps@ for normal
following rows. Restoration rows use a reserved length word
(@0xffffffff@) followed by @encodeOps@ and decode as
@rpMeta = Nothing@.
-}
rollbackEntryPrism ::
    Prism' ByteString (RollbackPoint [UtxoOp] BlockHash)
rollbackEntryPrism = prism' encode decode
  where
    encode RollbackPoint{rpInverses, rpMeta} =
        case rpMeta of
            Just (BlockHash bh) ->
                lenPrefixed bh <> encodeOps (flattenBatches rpInverses)
            Nothing ->
                noMetadataPrefix <> encodeOps (flattenBatches rpInverses)
    decode bs0 = do
        (n, rest0) <- readWord32 bs0
        if n == noMetadataMarker
            then do
                ops <- decodeOps rest0
                Just
                    RollbackPoint
                        { rpInverses = toBatches ops
                        , rpMeta = Nothing
                        }
            else do
                (bhBs, rest1) <- readFixedLen n rest0
                ops <- decodeOps rest1
                Just
                    RollbackPoint
                        { rpInverses = [ops]
                        , rpMeta = Just (BlockHash bhBs)
                        }

flattenBatches :: [[UtxoOp]] -> [UtxoOp]
flattenBatches = concat

toBatches :: [UtxoOp] -> [[UtxoOp]]
toBatches [] = []
toBatches ops = [ops]

noMetadataMarker :: Word32
noMetadataMarker = maxBound

noMetadataPrefix :: ByteString
noMetadataPrefix = word32BE noMetadataMarker

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
encodeOp (UtxoRestore txIn (Address addr) (TxOut txOut) slot (BlockHash bh)) =
    BS.singleton 2
        <> txInToBytes txIn
        <> lenPrefixed addr
        <> lenPrefixed txOut
        <> slotToBytes slot
        <> lenPrefixed bh

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
        2 -> do
            (txInBs, rest1) <- splitFixed 34 rest0
            txIn <- txInFromBytes txInBs
            (addrBs, rest2) <- readLenPrefixed rest1
            (txOutBs, rest3) <- readLenPrefixed rest2
            (slotBs, rest4) <- splitFixed 8 rest3
            slot <- slotFromBytes slotBs
            (bhBs, rest5) <- readLenPrefixed rest4
            Just
                ( UtxoRestore
                    txIn
                    (Address addrBs)
                    (TxOut txOutBs)
                    slot
                    (BlockHash bhBs)
                , rest5
                )
        _ -> Nothing

splitFixed :: Int -> ByteString -> Maybe (ByteString, ByteString)
splitFixed n bs
    | BS.length bs < n = Nothing
    | otherwise = Just (BS.splitAt n bs)

readLenPrefixed :: ByteString -> Maybe (ByteString, ByteString)
readLenPrefixed bs0 = do
    (n, rest0) <- readWord32 bs0
    readFixedLen n rest0

readFixedLen :: Word32 -> ByteString -> Maybe (ByteString, ByteString)
readFixedLen n bs =
    let len = fromIntegral n
     in if BS.length bs < len
            then Nothing
            else Just (BS.splitAt len bs)

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

word64BE :: Word64 -> ByteString
word64BE w =
    BS.pack
        [ fromIntegral (w `shiftR` n) .&. 0xFF
        | n <- [56, 48, 40, 32, 24, 16, 8, 0]
        ]

word64FromBE :: ByteString -> Maybe Word64
word64FromBE bs
    | BS.length bs /= 8 = Nothing
    | otherwise =
        Just $
            foldr
                (.|.)
                0
                ( zipWith
                    (\s b -> fromIntegral b `shiftL` s)
                    [56, 48, 40, 32, 24, 16, 8, 0]
                    (BS.unpack bs)
                )
