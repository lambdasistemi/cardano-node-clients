{-# LANGUAGE RecordWildCards #-}

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
    TxDirection (..),
    TxIdKey (..),
    TxSummaryKey (..),
    TxSummaryInput (..),
    TxSummaryOutput (..),
    TxSummaryValue (..),
    TxSummary (..),
    TxSummaryEntry (..),
    entryToSummary,
    summaryToEntry,
    summaryValueOf,
    summaryFromValue,
    txIdKeyOf,

    -- * Composite-key encoding
    summaryKeyToBytes,
    summaryKeyFromBytes,
    scopePrefix,
    txIdKeyToBytes,
    txIdKeyFromBytes,
    summaryValueToBytes,
    summaryValueFromBytes,
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

{- | Direction a transaction flows relative to the indexed tenant's
interest set. Kept opaque so applications can choose their own
vocabulary; treasury consumers use @"outbound"@ and @"inbound"@.
-}
newtype TxDirection = TxDirection {unTxDirection :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | Secondary lookup key for a tenant-local transaction id.
The tx-history store uses this to resolve @tenant + txid@ to the
canonical ordered 'TxSummaryKey' without scanning scopes.
-}
data TxIdKey = TxIdKey
    { tikTenant :: !TenantId
    , tikTxId :: !TxId
    }
    deriving stock (Eq, Ord, Show)

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

{- | One transaction input in a decoder-supplied detail view.
The storage layer keeps all fields opaque; downstream decoders choose
the exact rendering.
-}
data TxSummaryInput = TxSummaryInput
    { tsiTxIn :: !ByteString
    , tsiScope :: !(Maybe HistoryScope)
    , tsiValue :: !ByteString
    }
    deriving stock (Eq, Ord, Show)

{- | One transaction output in a decoder-supplied detail view. The
datum field is a summary, not a typed ledger value.
-}
data TxSummaryOutput = TxSummaryOutput
    { tsoAddress :: !ByteString
    , tsoValue :: !ByteString
    , tsoDatum :: !(Maybe ByteString)
    }
    deriving stock (Eq, Ord, Show)

{- | The value stored under a 'TxSummaryKey'. This is the
decoder-agnostic detail payload: the indexer persists it but never
interprets it.
-}
data TxSummaryValue = TxSummaryValue
    { tsvPayload :: !ByteString
    , tsvInputs :: ![TxSummaryInput]
    , tsvOutputs :: ![TxSummaryOutput]
    , tsvRedeemer :: !(Maybe ByteString)
    , tsvFee :: !(Maybe Word64)
    , tsvRequiredSigners :: ![ByteString]
    , tsvBlockHash :: !(Maybe ByteString)
    , tsvDirection :: !TxDirection
    }
    deriving stock (Eq, Ord, Show)

{- | A fully indexed transaction summary: ordered key plus the
decoder-supplied detail value.
-}
data TxSummary = TxSummary
    { txsKey :: !TxSummaryKey
    , txsPayload :: !ByteString
    , txsInputs :: ![TxSummaryInput]
    , txsOutputs :: ![TxSummaryOutput]
    , txsRedeemer :: !(Maybe ByteString)
    , txsFee :: !(Maybe Word64)
    , txsRequiredSigners :: ![ByteString]
    , txsBlockHash :: !(Maybe ByteString)
    , txsDirection :: !TxDirection
    }
    deriving stock (Eq, Ord, Show)

{- | A history entry: its composite key plus an opaque payload
blob forwarded unchanged to consumers.
-}
data TxSummaryEntry = TxSummaryEntry
    { tseKey :: !TxSummaryKey
    , tsePayload :: !ByteString
    , tseDirection :: !TxDirection
    }
    deriving stock (Eq, Ord, Show)

-- | Convert a legacy list row to an empty-detail 'TxSummary'.
entryToSummary :: TxSummaryEntry -> TxSummary
entryToSummary TxSummaryEntry{tseKey, tsePayload, tseDirection} =
    TxSummary
        { txsKey = tseKey
        , txsPayload = tsePayload
        , txsInputs = []
        , txsOutputs = []
        , txsRedeemer = Nothing
        , txsFee = Nothing
        , txsRequiredSigners = []
        , txsBlockHash = Nothing
        , txsDirection = tseDirection
        }

-- | Project a detailed summary back to the stable list-row shape.
summaryToEntry :: TxSummary -> TxSummaryEntry
summaryToEntry TxSummary{txsKey, txsPayload, txsDirection} =
    TxSummaryEntry
        { tseKey = txsKey
        , tsePayload = txsPayload
        , tseDirection = txsDirection
        }

-- | Extract the stored value from a 'TxSummary'.
summaryValueOf :: TxSummary -> TxSummaryValue
summaryValueOf TxSummary{..} =
    TxSummaryValue
        { tsvPayload = txsPayload
        , tsvInputs = txsInputs
        , tsvOutputs = txsOutputs
        , tsvRedeemer = txsRedeemer
        , tsvFee = txsFee
        , tsvRequiredSigners = txsRequiredSigners
        , tsvBlockHash = txsBlockHash
        , tsvDirection = txsDirection
        }

-- | Rebuild a 'TxSummary' from its ordered key and stored value.
summaryFromValue :: TxSummaryKey -> TxSummaryValue -> TxSummary
summaryFromValue txsKey TxSummaryValue{..} =
    TxSummary
        { txsKey
        , txsPayload = tsvPayload
        , txsInputs = tsvInputs
        , txsOutputs = tsvOutputs
        , txsRedeemer = tsvRedeemer
        , txsFee = tsvFee
        , txsRequiredSigners = tsvRequiredSigners
        , txsBlockHash = tsvBlockHash
        , txsDirection = tsvDirection
        }

-- | Build the tenant-local tx-id lookup key for a summary key.
txIdKeyOf :: TxSummaryKey -> TxIdKey
txIdKeyOf TxSummaryKey{tskTenant, tskTxId} =
    TxIdKey
        { tikTenant = tskTenant
        , tikTxId = tskTxId
        }

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

{- | Serialise a tenant-local tx-id lookup key.
Returns 'Nothing' when the tenant id exceeds the supported one-byte
length prefix.
-}
txIdKeyToBytes :: TxIdKey -> Maybe ByteString
txIdKeyToBytes (TxIdKey (TenantId tenant) (TxId tid))
    | BS.length tenant > maxKeyPartLength = Nothing
    | otherwise =
        Just $
            BS.cons (fromIntegral (BS.length tenant)) tenant
                <> lenPrefixed16 tid

-- | Parse a key produced by 'txIdKeyToBytes'.
txIdKeyFromBytes :: ByteString -> Maybe TxIdKey
txIdKeyFromBytes bs0 = do
    (tenant, rest0) <- readByteLenPrefixed bs0
    (tid, rest1) <- readLenPrefixed16 rest0
    if BS.null rest1
        then Just (TxIdKey (TenantId tenant) (TxId tid))
        else Nothing

-- | Serialise a 'TxSummaryValue' for the RocksDB value codec.
summaryValueToBytes :: TxSummaryValue -> ByteString
summaryValueToBytes TxSummaryValue{..} =
    summaryValueMagicV2
        <> lenPrefixed16 tsvPayload
        <> lenPrefixed16 (unTxDirection tsvDirection)
        <> list16 encodeInput tsvInputs
        <> list16 encodeOutput tsvOutputs
        <> maybeBytes tsvRedeemer
        <> maybeWord64 tsvFee
        <> list16 lenPrefixed16 tsvRequiredSigners
        <> maybeBytes tsvBlockHash

-- | Parse a value produced by 'summaryValueToBytes'.
summaryValueFromBytes :: ByteString -> Maybe TxSummaryValue
summaryValueFromBytes bs0 =
    case BS.stripPrefix summaryValueMagicV2 bs0 of
        Just rest ->
            case readVersionedSummaryValueV2 rest of
                Just value -> Just value
                Nothing -> Just (legacySummaryValue bs0)
        Nothing ->
            case BS.stripPrefix summaryValueMagicV1 bs0 of
                Just rest ->
                    case readVersionedSummaryValueV1 rest of
                        Just value -> Just value
                        Nothing -> Just (legacySummaryValue bs0)
                Nothing -> Just (legacySummaryValue bs0)

-- Internal helpers --------------------------------------------------

summaryValueMagicV1 :: ByteString
summaryValueMagicV1 = "\NULtx-summary-v1"

summaryValueMagicV2 :: ByteString
summaryValueMagicV2 = "\NULtx-summary-v2"

defaultDirection :: TxDirection
defaultDirection = TxDirection "outbound"

legacySummaryValue :: ByteString -> TxSummaryValue
legacySummaryValue payload =
    TxSummaryValue
        { tsvPayload = payload
        , tsvInputs = []
        , tsvOutputs = []
        , tsvRedeemer = Nothing
        , tsvFee = Nothing
        , tsvRequiredSigners = []
        , tsvBlockHash = Nothing
        , tsvDirection = defaultDirection
        }

readVersionedSummaryValueV1 :: ByteString -> Maybe TxSummaryValue
readVersionedSummaryValueV1 bs0 = do
    (payload, rest0) <- readLenPrefixed16 bs0
    readVersionedSummaryValueBody payload defaultDirection rest0

readVersionedSummaryValueV2 :: ByteString -> Maybe TxSummaryValue
readVersionedSummaryValueV2 bs0 = do
    (payload, rest0) <- readLenPrefixed16 bs0
    (direction, rest1) <- readLenPrefixed16 rest0
    readVersionedSummaryValueBody payload (TxDirection direction) rest1

readVersionedSummaryValueBody ::
    ByteString ->
    TxDirection ->
    ByteString ->
    Maybe TxSummaryValue
readVersionedSummaryValueBody payload direction bs0 = do
    (inputs, rest1) <- readList16 readInput bs0
    (outputs, rest2) <- readList16 readOutput rest1
    (redeemer, rest3) <- readMaybeBytes rest2
    (fee, rest4) <- readMaybeWord64 rest3
    (signers, rest5) <- readList16 readLenPrefixed16 rest4
    (blockHash, rest6) <- readMaybeBytes rest5
    if BS.null rest6
        then
            Just
                TxSummaryValue
                    { tsvPayload = payload
                    , tsvInputs = inputs
                    , tsvOutputs = outputs
                    , tsvRedeemer = redeemer
                    , tsvFee = fee
                    , tsvRequiredSigners = signers
                    , tsvBlockHash = blockHash
                    , tsvDirection = direction
                    }
        else Nothing

encodeInput :: TxSummaryInput -> ByteString
encodeInput TxSummaryInput{..} =
    lenPrefixed16 tsiTxIn
        <> maybeBytes (unHistoryScope <$> tsiScope)
        <> lenPrefixed16 tsiValue

readInput :: ByteString -> Maybe (TxSummaryInput, ByteString)
readInput bs0 = do
    (txin, rest0) <- readLenPrefixed16 bs0
    (scope, rest1) <- readMaybeBytes rest0
    (value, rest2) <- readLenPrefixed16 rest1
    Just
        ( TxSummaryInput
            { tsiTxIn = txin
            , tsiScope = HistoryScope <$> scope
            , tsiValue = value
            }
        , rest2
        )

encodeOutput :: TxSummaryOutput -> ByteString
encodeOutput TxSummaryOutput{..} =
    lenPrefixed16 tsoAddress
        <> lenPrefixed16 tsoValue
        <> maybeBytes tsoDatum

readOutput :: ByteString -> Maybe (TxSummaryOutput, ByteString)
readOutput bs0 = do
    (address, rest0) <- readLenPrefixed16 bs0
    (value, rest1) <- readLenPrefixed16 rest0
    (datum, rest2) <- readMaybeBytes rest1
    Just
        ( TxSummaryOutput
            { tsoAddress = address
            , tsoValue = value
            , tsoDatum = datum
            }
        , rest2
        )

list16 :: (a -> ByteString) -> [a] -> ByteString
list16 encode xs =
    word16BE (fromIntegral (length xs)) <> mconcat (encode <$> xs)

readList16 ::
    (ByteString -> Maybe (a, ByteString)) ->
    ByteString ->
    Maybe ([a], ByteString)
readList16 readOne bs0 = do
    (countBs, rest0) <- splitFixed 2 bs0
    n <- word16FromBE countBs
    go (fromIntegral n) [] rest0
  where
    go 0 acc rest = Just (reverse acc, rest)
    go n acc rest = do
        (x, rest') <- readOne rest
        go (n - 1 :: Int) (x : acc) rest'

maybeBytes :: Maybe ByteString -> ByteString
maybeBytes Nothing = BS.singleton 0
maybeBytes (Just bs) = BS.singleton 1 <> lenPrefixed16 bs

readMaybeBytes :: ByteString -> Maybe (Maybe ByteString, ByteString)
readMaybeBytes bs0 = do
    (tag, rest0) <- BS.uncons bs0
    case tag of
        0 -> Just (Nothing, rest0)
        1 -> do
            (bs, rest1) <- readLenPrefixed16 rest0
            Just (Just bs, rest1)
        _ -> Nothing

maybeWord64 :: Maybe Word64 -> ByteString
maybeWord64 Nothing = BS.singleton 0
maybeWord64 (Just w) = BS.singleton 1 <> word64BE w

readMaybeWord64 :: ByteString -> Maybe (Maybe Word64, ByteString)
readMaybeWord64 bs0 = do
    (tag, rest0) <- BS.uncons bs0
    case tag of
        0 -> Just (Nothing, rest0)
        1 -> do
            (w, rest1) <- splitFixed 8 rest0
            Just (Just (word64FromBE w), rest1)
        _ -> Nothing

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
