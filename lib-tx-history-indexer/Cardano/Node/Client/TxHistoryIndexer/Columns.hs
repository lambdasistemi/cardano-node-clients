{-# LANGUAGE GADTs #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Columns
License     : Apache-2.0
Description : Typed-column GADT for the tx-history indexer database

Database layout for the multi-tenant tx-history indexer expressed
against the 'Database.KV.Transaction' abstraction from
@kv-transactions@.

Two columns:

* 'HistoryCol' :: @KV TxSummaryKey TxSummaryValue@ — entries filed
  under the ordered composite key
  @lenTenant || tenant || lenScope || scope || slotBE || txid ||
  role@ (see "Cardano.Node.Client.TxHistoryIndexer.Types"), so a
  cursor seek to 'scopePrefix' yields every entry of one
  @(tenant, scope)@ in @(slot, txid, role)@ order. The value is
  the decoder-supplied summary detail, stored verbatim.

* 'HistoryBlockCol' :: @KV SlotNo HistoryBlock@ — the per-block
  rollback/resume log keyed by chain slot (big-endian, so a cursor
  walks blocks in slot order). Each row records the block hash and
  the composite keys filed for that block, so a roll-backward can
  delete every entry above a target slot and a resume can report the
  retained @(slot, blockHash)@ cursor. This is the history store's
  half of the plan's cursor model 2: separate persisted cursors per
  attached store.

Both the in-memory and RocksDB backends share these column
definitions verbatim — the backend choice happens at the
'Database.KV.InMemory' / 'Database.KV.RocksDB' boundary, not here.
-}
module Cardano.Node.Client.TxHistoryIndexer.Columns (
    -- * Column GADT
    Cols (..),

    -- * Rollback/resume log row
    HistoryBlock (..),

    -- * Codecs
    historyCodecs,
    historyColCodecs,
    historyBlockColCodecs,
) where

import Cardano.Node.Client.TxHistoryIndexer.Types (
    TxSummaryKey,
    TxSummaryValue,
    summaryKeyFromBytes,
    summaryKeyToBytes,
    summaryValueFromBytes,
    summaryValueToBytes,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Lens (Prism', prism')
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Dependent.Map (DMap)
import Data.GADT.Compare (
    GCompare (..),
    GEq (..),
    GOrdering (..),
 )
import Data.Type.Equality (type (:~:) (Refl))
import Data.Word (Word16, Word64)
import Database.KV.Transaction (
    Codecs (..),
    DSum ((:=>)),
    KV,
    fromList,
 )

{- | One row of the per-block rollback/resume log: the block hash
applied at a chain slot, and the composite keys filed for that block
(so a roll-backward can delete them).
-}
data HistoryBlock = HistoryBlock
    { hbBlockHash :: !ByteString
    , hbEntryKeys :: ![TxSummaryKey]
    }
    deriving stock (Eq, Show)

-- | The tx-history indexer database's column families.
data Cols c where
    -- | Entries table: @TxSummaryKey → TxSummaryValue@. Key is the
    -- ordered composite key; a cursor prefix-scan by
    -- 'Cardano.Node.Client.TxHistoryIndexer.Types.scopePrefix'
    -- yields every entry of one @(tenant, scope)@ in
    -- @(slot, txid, role)@ order.
    HistoryCol :: Cols (KV TxSummaryKey TxSummaryValue)
    -- | Per-block rollback/resume log: @SlotNo → HistoryBlock@,
    -- keyed by chain slot in big-endian byte order.
    HistoryBlockCol :: Cols (KV SlotNo HistoryBlock)

instance GEq Cols where
    geq HistoryCol HistoryCol = Just Refl
    geq HistoryBlockCol HistoryBlockCol = Just Refl
    geq _ _ = Nothing

instance GCompare Cols where
    gcompare HistoryCol HistoryCol = GEQ
    gcompare HistoryCol HistoryBlockCol = GLT
    gcompare HistoryBlockCol HistoryCol = GGT
    gcompare HistoryBlockCol HistoryBlockCol = GEQ

-- | Codecs for 'HistoryCol'.
historyColCodecs :: Codecs (KV TxSummaryKey TxSummaryValue)
historyColCodecs =
    Codecs
        { keyCodec = summaryKeyPrism
        , valueCodec = summaryValuePrism
        }

-- | Codecs for 'HistoryBlockCol'.
historyBlockColCodecs :: Codecs (KV SlotNo HistoryBlock)
historyBlockColCodecs =
    Codecs
        { keyCodec = slotPrism
        , valueCodec = historyBlockPrism
        }

-- | The full column-codec map for the tx-history database.
historyCodecs :: DMap Cols Codecs
historyCodecs =
    fromList
        [ HistoryCol :=> historyColCodecs
        , HistoryBlockCol :=> historyBlockColCodecs
        ]

-- Internal --------------------------------------------------------

summaryKeyPrism :: Prism' ByteString TxSummaryKey
summaryKeyPrism = prism' encodeKey summaryKeyFromBytes

encodeKey :: TxSummaryKey -> ByteString
encodeKey k = case summaryKeyToBytes k of
    Just bs -> bs
    Nothing ->
        error
            "summaryKeyPrism: tenant or scope exceeds 255 \
            \bytes — invariant violation"

summaryValuePrism :: Prism' ByteString TxSummaryValue
summaryValuePrism = prism' summaryValueToBytes summaryValueFromBytes

slotPrism :: Prism' ByteString SlotNo
slotPrism = prism' encode decode
  where
    encode (SlotNo s) = word64BE s
    decode bs
        | BS.length bs == 8 = Just (SlotNo (word64FromBE bs))
        | otherwise = Nothing

{- | Codec for a 'HistoryBlock' row:
@len16 blockHash || count16 || (len16 key)*@.
-}
historyBlockPrism :: Prism' ByteString HistoryBlock
historyBlockPrism = prism' encode decode
  where
    encode (HistoryBlock h keys) =
        lenPrefixed16 h
            <> word16BE (fromIntegral (length keys))
            <> mconcat (lenPrefixed16 . encodeKey <$> keys)
    decode bs0 = do
        (h, rest0) <- readLenPrefixed16 bs0
        (countBs, rest1) <- splitFixed 2 rest0
        n <- word16FromBE countBs
        (keys, rest2) <- readKeys (fromIntegral n) rest1
        if BS.null rest2
            then Just (HistoryBlock h keys)
            else Nothing
    readKeys 0 rest = Just ([], rest)
    readKeys n rest = do
        (kBytes, rest') <- readLenPrefixed16 rest
        k <- summaryKeyFromBytes kBytes
        (ks, rest'') <- readKeys (n - 1 :: Int) rest'
        Just (k : ks, rest'')

lenPrefixed16 :: ByteString -> ByteString
lenPrefixed16 bs = word16BE (fromIntegral (BS.length bs)) <> bs

readLenPrefixed16 :: ByteString -> Maybe (ByteString, ByteString)
readLenPrefixed16 bs0 = do
    (lenBs, rest0) <- splitFixed 2 bs0
    n <- word16FromBE lenBs
    splitFixed (fromIntegral n) rest0

splitFixed :: Int -> ByteString -> Maybe (ByteString, ByteString)
splitFixed n bs
    | BS.length bs < n = Nothing
    | otherwise = Just (BS.splitAt n bs)

word16BE :: Word16 -> ByteString
word16BE w =
    BS.pack
        [ fromIntegral (w `shiftR` 8) .&. 0xFF
        , fromIntegral w .&. 0xFF
        ]

word16FromBE :: ByteString -> Maybe Word16
word16FromBE bs
    | BS.length bs /= 2 = Nothing
    | otherwise =
        Just $
            foldr (.|.) 0 $
                zipWith
                    (\b s -> fromIntegral b `shiftL` s)
                    (BS.unpack bs)
                    [8, 0 :: Int]

word64BE :: Word64 -> ByteString
word64BE w =
    BS.pack
        [ fromIntegral (w `shiftR` n) .&. 0xFF
        | n <- [56, 48, 40, 32, 24, 16, 8, 0]
        ]

word64FromBE :: ByteString -> Word64
word64FromBE =
    foldr (.|.) 0
        . zipWith
            (\s b -> fromIntegral b `shiftL` s)
            [56, 48, 40, 32, 24, 16, 8, 0]
        . BS.unpack
