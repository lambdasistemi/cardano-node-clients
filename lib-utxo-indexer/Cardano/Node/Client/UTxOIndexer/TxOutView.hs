{- |
Module      : Cardano.Node.Client.UTxOIndexer.TxOutView
Description : Ledger-free decoding of stored outputs into assets and datum
License     : Apache-2.0

Decodes a stored transaction output ('TxOut' raw CBOR bytes) into the
two views the asset index and the wire protocol need: the
multi-asset quantities the output carries and the datum view
(none, hash, or the exact inline CBOR bytes).

The library stays ledger-decoupled: the decoder walks the stable CDDL
output grammar — the legacy array form (Shelley–Alonzo, optional
32-byte datum hash as the third element) and the post-Alonzo map form
(@0@ address, @1@ value, @2@ optional datum option, @3@ optional
script reference); the value is either a coin @uint@ or the pair
@[coin, multiasset]@. The unit suite cross-checks this decoder
against the ledger's own decoding of the same bytes for every
Shelley-family era.

Undecodable bytes are a 'Left' — never an empty view: an output the
decoder cannot read makes the asset index incomplete, not silently
empty.
-}
module Cardano.Node.Client.UTxOIndexer.TxOutView (
    -- * Decoded views
    TxOutView (..),
    DatumView (..),

    -- * Decoding
    TxOutViewError (..),
    decodeTxOutView,
) where

import Cardano.Node.Client.UTxOIndexer.Types (
    AssetName (..),
    PolicyId (..),
    TxOut (..),
    mkAssetName,
    mkPolicyId,
 )
import Codec.CBOR.Decoding (
    Decoder,
    TokenType (..),
    decodeBytes,
    decodeInteger,
    decodeListLen,
    decodeMapLen,
    decodeTag,
    decodeWord,
    decodeWord64,
    peekTokenType,
 )
import Codec.CBOR.Read (deserialiseFromBytes)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (nub)
import Data.Word (Word64)

{- | The two derived views of one stored output: the multi-asset
quantities and the datum view. Derived, never stored.
-}
data TxOutView = TxOutView
    { tovAssets :: [(PolicyId, AssetName, Word64)]
    -- ^ The output's multi-asset entries with positive quantities.
    -- Coin-only and Byron-shaped outputs yield none.
    , tovDatum :: DatumView
    -- ^ The datum view derived from the same bytes.
    }
    deriving stock (Eq, Show)

{- | A datum view. 'InlineDatum' carries the exact CBOR bytes inside
the tag-24 wrapper — a byte-for-byte slice of the stored output,
never re-encoded.
-}
data DatumView
    = NoDatum
    | -- | The 32-byte hash the output carries.
      DatumHash !ByteString
    | -- | The exact inline-datum CBOR bytes.
      InlineDatum !ByteString
    deriving stock (Eq, Show)

-- | Why a stored output could not be decoded.
newtype TxOutViewError = TxOutViewError String
    deriving stock (Eq, Show)

{- | Decode a stored output into its 'TxOutView'. Pure and total over
the input bytes: any deviation from the output grammar (including
trailing bytes) is a 'Left'.
-}
decodeTxOutView :: TxOut -> Either TxOutViewError TxOutView
decodeTxOutView (TxOut bytes) =
    case deserialiseFromBytes decodeOutput (BSL.fromStrict bytes) of
        Left err ->
            Left (TxOutViewError (show err))
        Right (rest, view)
            | BSL.null rest -> Right view
            | otherwise ->
                Left (TxOutViewError "trailing bytes after output")

decodeOutput :: forall s. Decoder s TxOutView
decodeOutput = do
    tt <- peekTokenType
    case tt of
        TypeListLen -> decodeLegacy
        TypeMapLen -> decodePostAlonzo
        _ -> fail "output: expected array or map"

{- | Legacy array form: @[address, value]@ or
@[address, value, datumHash]@ (Alonzo).
-}
decodeLegacy :: Decoder s TxOutView
decodeLegacy = do
    n <- decodeListLen
    case n of
        2 -> do
            _addr <- decodeAddress
            assets <- decodeValue
            pure (TxOutView assets NoDatum)
        3 -> do
            _addr <- decodeAddress
            assets <- decodeValue
            TxOutView assets . DatumHash <$> decodeDatumHashBytes
        _ -> fail "legacy output: expected 2 or 3 elements"

-- | Post-Alonzo map form with integer keys @0..3@.
decodePostAlonzo :: Decoder s TxOutView
decodePostAlonzo = do
    n <- decodeMapLen
    (mAddr, mAssets, datum) <- go n [] Nothing Nothing NoDatum
    case (mAddr, mAssets) of
        (Nothing, _) -> fail "post-alonzo output: missing address (key 0)"
        (_, Nothing) -> fail "post-alonzo output: missing value (key 1)"
        (Just (), Just as) -> pure (TxOutView as datum)
  where
    go 0 _seen mAddr mAssets datum = pure (mAddr, mAssets, datum)
    go k seen mAddr mAssets datum = do
        key <- decodeWord
        when (key `elem` seen) $
            fail "post-alonzo output: duplicate key"
        case key of
            0 -> do
                _addr <- decodeAddress
                go (k - 1) (key : seen) (Just ()) mAssets datum
            1 -> do
                as <- decodeValue
                go (k - 1) (key : seen) mAddr (Just as) datum
            2 -> do
                d <- decodeDatumOption
                go (k - 1) (key : seen) mAddr mAssets d
            3 -> do
                _scriptRef <- decodeScriptRef
                go (k - 1) (key : seen) mAddr mAssets datum
            _ -> fail "post-alonzo output: unknown key"

{- | A script reference: the pinned Babbage grammar encodes it as
tag 24 wrapping the script's CBOR bytes.
-}
decodeScriptRef :: Decoder s ()
decodeScriptRef = do
    t <- decodeTag
    when (t /= 24) $
        fail "script reference: expected tag 24"
    _ <- decodeBytes
    pure ()

-- | The datum option: @[0, hash]@ or @[1, tag24(cbor)]@.
decodeDatumOption :: Decoder s DatumView
decodeDatumOption = do
    n <- decodeListLen
    when (n /= 2) $
        fail "datum option: expected 2 elements"
    tag <- decodeWord
    case tag of
        0 -> DatumHash <$> decodeDatumHashBytes
        1 -> do
            t <- decodeTag
            when (t /= 24) $
                fail "inline datum: expected tag 24"
            InlineDatum <$> decodeBytes
        _ -> fail "datum option: unknown variant"

-- | A datum hash: exactly 32 bytes as carried.
decodeDatumHashBytes :: Decoder s ByteString
decodeDatumHashBytes = do
    bs <- decodeBytes
    when (BS.length bs /= 32) $
        fail "datum hash: expected 32 bytes"
    pure bs

-- | An address: any byte string (the value is not interpreted).
decodeAddress :: Decoder s ByteString
decodeAddress = decodeBytes

{- | A value: a coin @uint@ (no assets) or the pair
@[coin, multiasset]@.
-}
decodeValue :: forall s. Decoder s [(PolicyId, AssetName, Word64)]
decodeValue = do
    tt <- peekTokenType
    case tt of
        TypeUInt -> [] <$ decodeWord64
        TypeListLen -> do
            n <- decodeListLen
            unless (n == 2) $
                fail "value: expected coin or [coin, multiasset]"
            _coin <- decodeWord64
            decodeMultiAsset
        _ -> fail "value: expected uint or pair"

{- | The multi-asset map: @policy(28) -> name(0..32) -> quantity@.
Quantities must be positive and fit a 'Word64'; zero-quantity
entries are skipped; duplicate keys are a decode failure (the
ledger never writes them).
-}
decodeMultiAsset ::
    forall s. Decoder s [(PolicyId, AssetName, Word64)]
decodeMultiAsset = do
    n <- decodeMapLen
    policyEntries <- mapM (const decodePolicy) [1 :: Int .. n]
    let policies = fmap fst policyEntries
    when (length (nub policies) /= length policies) $
        fail "multiasset: duplicate policy"
    pure (concatMap snd policyEntries)
  where
    decodePolicy :: Decoder s (PolicyId, [(PolicyId, AssetName, Word64)])
    decodePolicy = do
        pBs <- decodeBytes
        policy <- case mkPolicyId pBs of
            Just p -> pure p
            Nothing -> fail "multiasset: policy id is not 28 bytes"
        m <- decodeMapLen
        nameEntries <- mapM (const (decodeName policy)) [1 :: Int .. m]
        let names = fmap fst nameEntries
        when (length (nub names) /= length names) $
            fail "multiasset: duplicate asset name"
        pure (policy, concatMap snd nameEntries)

    decodeName ::
        PolicyId -> Decoder s (AssetName, [(PolicyId, AssetName, Word64)])
    decodeName policy = do
        nBs <- decodeBytes
        aname <- case mkAssetName nBs of
            Just a -> pure a
            Nothing -> fail "multiasset: asset name longer than 32 bytes"
        q <- decodeInteger
        if q < 0
            then fail "multiasset: negative quantity"
            else
                if q == 0
                    then pure (aname, [])
                    else
                        if q > toInteger (maxBound :: Word64)
                            then fail "multiasset: quantity overflows Word64"
                            else pure (aname, [(policy, aname, fromInteger q)])
