{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Types
Description : Domain types and ordered key codec for tx-history storage
License     : Apache-2.0

Era-agnostic types for the multi-tenant transaction-history
indexer. Every history entry is filed under a composite
'TxSummaryKey' whose on-disk byte form orders entries by
@(tenant, scope, slot, txid, role)@.

= Composite-key encoding

Tenant ids and history scopes are variable-length, user-chosen
byte strings. To keep prefix scans correct across mixed
lengths — so tenant @"a"@ never bleeds into tenant @"ab"@ — the
variable-length parts are length-prefixed:

@
key = lenTenant || tenant || lenScope || scope
        || slotBE(8) || txidLen(2 BE) || txid || roleLen(2 BE) || role
@

@lenTenant@ and @lenScope@ are single bytes (tenant/scope ids
fit comfortably under 256 bytes). The slot is big-endian so
byte ordering matches numeric ordering; the txid and role are
length-prefixed so the codec round-trips exactly.
-}
module Cardano.Node.Client.TxHistoryIndexer.Types (
    -- * Indexer domain types
    TenantId (..),
    HistoryScope (..),
    TxId (..),
    TxRole (..),
    TxSummaryKey (..),
    TxSummaryEntry (..),

    -- * Composite-key encoding
    summaryKeyToBytes,
    summaryKeyFromBytes,
    scopePrefix,
) where

import Cardano.Slotting.Slot (SlotNo (..))
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word16, Word64)

{- | Opaque tenant identifier. Each tenant's history is
isolated: a query scoped to one tenant never observes
another tenant's entries.
-}
newtype TenantId = TenantId {unTenantId :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | History scope within a tenant — for example an address
or a logical partition. Queries are scoped to a single
@(tenant, scope)@ pair.
-}
newtype HistoryScope = HistoryScope {unHistoryScope :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Transaction id, raw bytes (typically 32).
newtype TxId = TxId {unTxId :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | The role a transaction plays for the entry — for example
@"input"@ or @"output"@. Kept as opaque bytes so the storage
layer never interprets it.
-}
newtype TxRole = TxRole {unTxRole :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | Composite key under which a history entry is filed.

The on-disk byte form orders entries by
@(tenant, scope, slot, txid, role)@; see the module header for
the length-prefix rationale.
-}
data TxSummaryKey = TxSummaryKey
    { tskTenant :: !TenantId
    , tskScope :: !HistoryScope
    , tskSlot :: !SlotNo
    , tskTxId :: !TxId
    , tskRole :: !TxRole
    }
    deriving stock (Eq, Ord, Show)

{- | A history entry: its composite key plus an opaque payload
blob forwarded unchanged to consumers.
-}
data TxSummaryEntry = TxSummaryEntry
    { tseKey :: !TxSummaryKey
    , tsePayload :: !ByteString
    }
    deriving stock (Eq, Ord, Show)

{- | Maximum length accepted for a tenant id or history scope.
These fit comfortably under this bound; reject anything larger
so the single-byte length prefix stays sufficient.
-}
maxKeyPartLength :: Int
maxKeyPartLength = 255

{- | Serialise a 'TxSummaryKey' to its ordered composite-key
byte form. Returns 'Nothing' if the tenant or scope exceeds
'maxKeyPartLength'.

Inverse of 'summaryKeyFromBytes'.
-}
summaryKeyToBytes :: TxSummaryKey -> Maybe ByteString
summaryKeyToBytes
    (TxSummaryKey tenant scope (SlotNo slot) (TxId tid) (TxRole role)) = do
        prefix <- scopePrefix tenant scope
        pure $
            prefix
                <> word64BE slot
                <> lenPrefixed16 tid
                <> lenPrefixed16 role

{- | Parse a composite key produced by 'summaryKeyToBytes'.
Returns 'Nothing' on any structural mismatch or trailing
garbage.
-}
summaryKeyFromBytes :: ByteString -> Maybe TxSummaryKey
summaryKeyFromBytes bs0 = do
    (tenant, rest0) <- readByteLenPrefixed bs0
    (scope, rest1) <- readByteLenPrefixed rest0
    (slotBs, rest2) <- splitFixed 8 rest1
    (tid, rest3) <- readLenPrefixed16 rest2
    (role, rest4) <- readLenPrefixed16 rest3
    if BS.null rest4
        then
            Just $
                TxSummaryKey
                    (TenantId tenant)
                    (HistoryScope scope)
                    (SlotNo (word64FromBE slotBs))
                    (TxId tid)
                    (TxRole role)
        else Nothing

{- | The byte-string prefix corresponding to "all entries
under this @(tenant, scope)@" — i.e.
@lenTenant || tenant || lenScope || scope@. Pass to a cursor
as the seek prefix for a scope scan.

Returns 'Nothing' if the tenant or scope exceeds
'maxKeyPartLength'.
-}
scopePrefix :: TenantId -> HistoryScope -> Maybe ByteString
scopePrefix (TenantId tenant) (HistoryScope scope)
    | BS.length tenant > maxKeyPartLength = Nothing
    | BS.length scope > maxKeyPartLength = Nothing
    | otherwise =
        Just $
            BS.cons (fromIntegral (BS.length tenant)) tenant
                <> BS.cons (fromIntegral (BS.length scope)) scope

-- Internal helpers --------------------------------------------------

readByteLenPrefixed :: ByteString -> Maybe (ByteString, ByteString)
readByteLenPrefixed bs0 = do
    (lenByte, rest0) <- BS.uncons bs0
    splitFixed (fromIntegral lenByte) rest0

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

word16FromBE :: ByteString -> Maybe Word16
word16FromBE bs
    | BS.length bs /= 2 = Nothing
    | otherwise =
        let shifted =
                zipWith
                    (\b s -> fromIntegral b `shiftL` s)
                    (BS.unpack bs)
                    [8, 0 :: Int]
         in Just $ foldr (.|.) 0 shifted
