{- |
Module      : Cardano.Node.Client.UTxOIndexer.Types
Description : Domain types for the address->UTxO indexer
License     : Apache-2.0

Era-agnostic, ledger-decoupled types used by the indexer's
'Cardano.Node.Client.UTxOIndexer.Columns' database layout
and by the NDJSON wire. Address bytes, transaction inputs,
and transaction outputs are all kept as raw 'ByteString' so
the indexer never decodes era-specific structure: it stores
exactly what chain-sync gives it and forwards exactly that
to consumers (as base16 over the wire).

= Composite-key encoding

Cardano addresses are variable-length (Byron and Shelley
differ; Shelley itself has multiple shapes). To keep prefix
scans correct across mixed lengths, the address is
length-prefixed:

@
key = lenByte || addressBytes || txIdBytes || ixBE16
@

@lenByte@ is a single byte holding the address length in
bytes (Cardano addresses fit comfortably in 0..255). Two
addresses with different lengths therefore have distinct
leading bytes, so a 'Cursor' seek to @lenByte || addr@
lands inside the right address bucket and never bleeds into
a neighbouring bucket.

This is the @aiken-csmt@ trick of prepending the @TxIn@
with its address so prefix scans under an address yield
every UTxO at that address — generalised to variable-length
addresses via the explicit length byte.
-}
module Cardano.Node.Client.UTxOIndexer.Types (
    -- * Indexer domain types
    Address (..),
    TxIn (..),
    TxOut (..),
    AddrKey (..),
    SlotNo (..),
    BlockHash (..),

    -- * Composite-key encoding (AddressIndex column)
    addrKeyToBytes,
    addrKeyFromBytes,
    addressPrefix,

    -- * TxIn key encoding (TxInCol column)
    txInToBytes,
    txInFromBytes,

    -- * Slot encoding (RollbackCol column key)
    slotToBytes,
    slotFromBytes,
) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word16, Word64, Word8)

{- | Raw payment-address bytes as observed in a 'TxOut'.
The indexer does not parse Cardano address structure;
consumers can pass either a bech32 string or a base16-encoded
byte string on the wire and we match by prefix on the
canonical raw bytes recorded during apply-block.
-}
newtype Address = Address {unAddress :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | A transaction input: the producing transaction's
32-byte hash plus the output index within that
transaction.
-}
data TxIn = TxIn
    { txInId :: !ByteString
    -- ^ Transaction ID (32 raw bytes).
    , txInIx :: !Word16
    -- ^ Output index inside the transaction body.
    }
    deriving stock (Eq, Ord, Show)

{- | Raw CBOR-encoded transaction output. The indexer
forwards these unchanged on the wire (as base16);
consumers parse value/datum themselves if they need
to.
-}
newtype TxOut = TxOut {unTxOut :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | Composite key under which UTxOs are indexed.

The on-disk byte form is @lenByte || addressBytes ||
txIdBytes || ixBE16@; see the module header for the
length-prefix rationale.
-}
data AddrKey = AddrKey
    { addrKeyAddress :: !Address
    , addrKeyTxIn :: !TxIn
    }
    deriving stock (Eq, Ord, Show)

{- | Maximum address length the indexer accepts. Cardano
addresses fit comfortably under this; reject anything
larger so the single-byte length prefix stays sufficient.
-}
maxAddressLength :: Int
maxAddressLength = 255

{- | Serialise an 'AddrKey' to its composite-key byte
form. Returns 'Nothing' if the address exceeds
'maxAddressLength' (an invariant violation: the indexer
never observes such an address from real ledger data).

Inverse of 'addrKeyFromBytes'.
-}
addrKeyToBytes :: AddrKey -> Maybe ByteString
addrKeyToBytes (AddrKey (Address addr) (TxIn tid ix))
    | BS.length addr > maxAddressLength = Nothing
    | otherwise =
        Just $
            BS.cons (fromIntegral (BS.length addr)) addr
                <> tid
                <> word16ToBE ix

{- | Parse a composite key produced by 'addrKeyToBytes'.
Returns 'Nothing' if the byte string is shorter than
required, declares an address length that does not match
the remaining bytes, or has trailing garbage past the
@ixBE16@.
-}
addrKeyFromBytes :: ByteString -> Maybe AddrKey
addrKeyFromBytes bs0 = do
    (lenByte, rest0) <- BS.uncons bs0
    let addrLen = fromIntegral lenByte
    if BS.length rest0 /= addrLen + 32 + 2
        then Nothing
        else do
            let (addr, rest1) = BS.splitAt addrLen rest0
                (tid, ixBs) = BS.splitAt 32 rest1
            ix <- word16FromBE ixBs
            pure $ AddrKey (Address addr) (TxIn tid ix)

{- | The byte-string prefix corresponding to "all UTxOs
at this address" — i.e. @lenByte || addressBytes@. Pass
to a 'Cursor' as the seek prefix for a snapshot scan.

Returns 'Nothing' for addresses exceeding
'maxAddressLength' (same invariant as 'addrKeyToBytes').
-}
addressPrefix :: Address -> Maybe ByteString
addressPrefix (Address bs)
    | BS.length bs > maxAddressLength = Nothing
    | otherwise =
        Just $ BS.cons (fromIntegral (BS.length bs)) bs

-- TxIn encoding -----------------------------------------------------

{- | Serialise a 'TxIn' to its 34-byte fixed-width
form: @txId (32 bytes) || ix (Word16 BE)@. Total: 34
bytes.

Used as the key codec of the 'TxInCol' column.
-}
txInToBytes :: TxIn -> ByteString
txInToBytes (TxIn tid ix) = tid <> word16ToBE ix

{- | Parse the inverse of 'txInToBytes'. Returns
'Nothing' if the byte string is not exactly 34 bytes
or if the embedded TxId is not 32 bytes.
-}
txInFromBytes :: ByteString -> Maybe TxIn
txInFromBytes bs
    | BS.length bs /= 34 = Nothing
    | otherwise =
        let (tid, ixBs) = BS.splitAt 32 bs
         in TxIn tid <$> word16FromBE ixBs

-- Slot encoding ------------------------------------------------------

{- | Cardano slot number. Stored as the 'KeyOf' of the
rollback column; encoded big-endian so cursor ordering
matches numeric ordering (a lower slot lexicographically
precedes a higher slot at the byte level).
-}
newtype SlotNo = SlotNo {unSlotNo :: Word64}
    deriving newtype (Eq, Ord, Show)

{- | Cardano block hash, raw 32 bytes. Stored alongside
the slot in @await@ observations and (in a follow-up
patch) wired through to the rollback column for
chain-rewind fidelity.
-}
newtype BlockHash = BlockHash {unBlockHash :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Serialise a 'SlotNo' to its 8-byte big-endian form.
slotToBytes :: SlotNo -> ByteString
slotToBytes (SlotNo w) = word64BE w

{- | Parse the inverse of 'slotToBytes'. Returns 'Nothing'
if the byte string is not exactly 8 bytes.
-}
slotFromBytes :: ByteString -> Maybe SlotNo
slotFromBytes bs
    | BS.length bs /= 8 = Nothing
    | otherwise = Just $ SlotNo $ word64FromBE bs

-- Internal helpers --------------------------------------------------

word16ToBE :: Word16 -> ByteString
word16ToBE w =
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
        let bytes :: [Word8]
            bytes = BS.unpack bs
            shifted :: [Word16]
            shifted =
                zipWith
                    (\b s -> fromIntegral b `shiftL` s)
                    bytes
                    [8, 0]
         in Just $ foldr (.|.) 0 shifted
