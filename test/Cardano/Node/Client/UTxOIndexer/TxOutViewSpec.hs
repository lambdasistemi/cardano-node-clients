{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.TxOutViewSpec
Description : Stored-output decoder cross-checked against the ledger
License     : Apache-2.0

Proves the ledger-free stored-output decoder against the ledger
itself: for ledger-generated outputs of every Shelley-family era plus
Byron-converted outputs, the decoded asset list and datum view equal
the ledger's own decoding of the same stored bytes, and inline datum
bytes are a byte slice of the stored output. Expected values are read
back from the ledger-decoded output at run time.
-}
module Cardano.Node.Client.UTxOIndexer.TxOutViewSpec (spec) where

import Cardano.Chain.Common qualified as ByronCommon
import Cardano.Crypto.Hash.Class (Hash (UnsafeHash), hashToBytes)
import Cardano.Ledger.Address (
    Addr (..),
    BootstrapAddress (..),
 )
import Cardano.Ledger.Allegra.Scripts (pattern RequireTimeStart)
import Cardano.Ledger.Alonzo.TxOut (dataHashTxOutL, datumTxOutF)
import Cardano.Ledger.Api.Era (
    AllegraEra,
    AlonzoEra,
    BabbageEra,
    ConwayEra,
    DijkstraEra,
    MaryEra,
    ShelleyEra,
 )
import Cardano.Ledger.Api.Tx.Out (
    AlonzoEraTxOut,
    BabbageEraTxOut,
    datumTxOutL,
    mkBasicTxOut,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.Binary (
    DecoderError,
    decCBOR,
    decodeFullDecoder,
    serialize',
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (fromNativeScript)
import Cardano.Ledger.Core qualified as Ledger

import Cardano.Ledger.Hashes (
    DataHash,
    ScriptHash (..),
    extractHash,
    originalBytes,
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Ledger.Plutus.Data (
    Datum (..),
    binaryDataToData,
    makeBinaryData,
 )
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.UTxOIndexer.TxOutView qualified as View
import Cardano.Node.Client.UTxOIndexer.Types (
    AssetName (..),
    PolicyId (..),
    TxOut (..),
    mkAssetName,
    mkPolicyId,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Either (isRight)
import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Proxy (Proxy (..))
import Data.Word (Word64, Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (
    Expectation,
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )
import Test.QuickCheck (
    Gen,
    Property,
    arbitrary,
    checkCoverage,
    choose,
    counterexample,
    cover,
    elements,
    forAll,
    frequency,
    oneof,
    property,
    sublistOf,
    suchThat,
    (===),
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer.TxOutView" $ do
        describe "ledger cross-check per era (I9)" $ do
            it "Shelley coin-only output" $
                checkBasic (Proxy @ShelleyEra)
            it "Allegra coin-only output" $
                checkBasic (Proxy @AllegraEra)
            it "Mary multi-asset output" $
                checkMaryAssets (Proxy @MaryEra)
            it "Alonzo multi-asset + datum hash output" $
                checkDatumHash (Proxy @AlonzoEra)
            it "Babbage multi-asset + inline datum output" $
                checkInlineDatum (Proxy @BabbageEra)
            it "Conway multi-asset output, no datum" $
                checkMaryAssets (Proxy @ConwayEra)
            it "Conway multi-asset + inline datum output" $
                checkInlineDatum (Proxy @ConwayEra)
            it "Conway datum-hash output" $
                checkDatumHash (Proxy @ConwayEra)
            it "Dijkstra multi-asset + datum hash output" $
                checkDatumHash (Proxy @DijkstraEra)
            it "Babbage multi-asset + inline datum + reference script output" $
                checkScriptRef (Proxy @BabbageEra)
            it "Conway multi-asset + reference script output" $
                checkScriptRef (Proxy @ConwayEra)
            it "Byron-converted output (Conway shape, coin-only)" $ do
                let out =
                        mkBasicTxOut @ConwayEra
                            addr
                            (inject (Coin 12_345_678))
                    stored = store @ConwayEra out
                View.decodeTxOutView stored
                    `shouldBe` Right
                        (View.TxOutView [] View.NoDatum)

        describe "undecodable bytes (DM5)" $ do
            it "non-CBOR bytes are a decode error, never an empty view" $
                View.decodeTxOutView (TxOut "value-bytes-0")
                    `shouldSatisfy` isLeftView
            it "empty bytes are a decode error" $
                View.decodeTxOutView (TxOut BS.empty)
                    `shouldSatisfy` isLeftView
            it "truncated real output bytes are a decode error" $ do
                let stored = store @ConwayEra maryOut
                View.decodeTxOutView (TxOut (BS.take 10 (unTxOut stored)))
                    `shouldSatisfy` isLeftView
            it "zero-quantity entries are not rows" $ do
                -- Raw bytes carrying a zero-quantity asset: the
                -- ledger encoder may normalise zero entries away, so
                -- the bytes are hand-built from the grammar.
                View.decodeTxOutView (TxOut rawZeroQtyOutput)
                    `shouldBe` Right
                        ( View.TxOutView
                            { View.tovAssets = []
                            , View.tovDatum = View.NoDatum
                            }
                        )
            it "negative quantities are a decode error" $
                View.decodeTxOutView (TxOut rawNegativeQtyOutput)
                    `shouldSatisfy` isLeftView
            it "a map output without the address key is a decode error" $
                View.decodeTxOutView
                    (TxOut (BS.pack [0xA1, 0x01, 0x18, 0x64]))
                    `shouldSatisfy` isLeftView
            it "duplicate map keys are a decode error" $
                View.decodeTxOutView
                    ( TxOut
                        ( BS.pack
                            [ 0xA3
                            , 0x00
                            , 0x41
                            , 0xAA -- address
                            , 0x01
                            , 0x18
                            , 0x64 -- value: coin
                            , 0x01
                            , 0x18
                            , 0x65 -- duplicate value key
                            ]
                        )
                    )
                    `shouldSatisfy` isLeftView
            it "a script reference outside tag 24 is a decode error" $ do
                let badRef =
                        BS.pack
                            [ 0xA3
                            , 0x00
                            , 0x41
                            , 0xAA -- address
                            , 0x01
                            , 0x18
                            , 0x64 -- value: coin
                            , 0x03
                            , 0x41
                            , 0xAB -- script ref: bare bytes
                            ]
                View.decodeTxOutView (TxOut badRef)
                    `shouldSatisfy` isLeftView

        describe "integers of every CBOR width, against the ledger" $
            it "decodes exactly the outputs the ledger decodes, to the ledger's view" $
                property $
                    checkCoverage $
                        forAll genWidthOutput agreesWithLedger

-- * Ledger-side construction and oracle

{- | The shared bootstrap address: valid in every era and needs no
key material.
-}
addr :: Addr
addr =
    AddrBootstrap
        ( BootstrapAddress
            ( either
                (error . show)
                id
                ( ByronCommon.decodeAddressBase58
                    "DdzFFzCqrhsq3KjLtT51mESbZ4RepiHPzLqEhamexVFTJpGbCXmh7qSxnHvaL88QmtVTD1E1sjx8Z1ZNDhYmcBV38ZjDST9kYVxSkhcw"
                )
            )
        )

p1 :: Mary.PolicyID
p1 =
    Mary.PolicyID
        (ScriptHash (UnsafeHash (SBS.toShort (BS.replicate 28 0x11))))

p2 :: Mary.PolicyID
p2 =
    Mary.PolicyID
        (ScriptHash (UnsafeHash (SBS.toShort (BS.replicate 28 0x22))))

sampleDatumHash :: DataHash
sampleDatumHash =
    unsafeMakeSafeHash
        (UnsafeHash (SBS.toShort (BS.replicate 32 0xAB)))

inlineDatumBytes :: ByteString
inlineDatumBytes = BS.pack [0x18, 0x2A]
{- ^ CBOR of the Plutus data @I 42@: a single valid datum so the
ledger's own round trip accepts it.
-}

mkInlineDatum :: forall era. (Ledger.Era era) => Datum era
mkInlineDatum =
    Datum
        ( either
            (error . show)
            id
            (makeBinaryData (SBS.toShort inlineDatumBytes))
        )

maryValue :: Mary.MaryValue
maryValue =
    Mary.valueFromList
        (Coin 100)
        [ (p1, Mary.AssetName (SBS.toShort "tok"), 42)
        , (p1, Mary.AssetName SBS.empty, 7)
        , (p1, Mary.AssetName (SBS.toShort "\xF0\x9F\x92\x8A"), 3)
        , (p2, Mary.AssetName (SBS.toShort "tok"), 99)
        , (p1, Mary.AssetName (SBS.toShort (BS.replicate 32 0xEE)), 1_000)
        ]

maryOut :: Ledger.TxOut ConwayEra
maryOut = mkBasicTxOut addr maryValue

store :: forall era. (Ledger.EraTxOut era) => Ledger.TxOut era -> TxOut
store out = TxOut (serialize' (Ledger.eraProtVerLow @era) out)

{- | Decode the stored bytes with the ledger and read the asset list
back from the decoded output's value.
-}
ledgerAssets ::
    forall era.
    (Ledger.EraTxOut era, Ledger.Value era ~ Mary.MaryValue) =>
    Proxy era ->
    TxOut ->
    [(PolicyId, AssetName, Word64)]
ledgerAssets _ stored =
    case decodeFullDecoder
            (Ledger.eraProtVerLow @era)
            "txout"
            decCBOR
            (BSL.fromStrict (unTxOut stored)) ::
            Either DecoderError (Ledger.TxOut era) of
        Left e -> error (show e)
        Right out' ->
            let Mary.MaryValue _ ma = out' ^. Ledger.valueTxOutL
             in [ ( pol
                  , nm
                  , fromIntegral q
                  )
                | ( Mary.PolicyID (ScriptHash (UnsafeHash p))
                    , Mary.AssetName n
                    , q
                    ) <-
                    Mary.flattenMultiAsset ma
                , q > 0
                , Just pol <- [mkPolicyId (SBS.fromShort p)]
                , Just nm <- [mkAssetName (SBS.fromShort n)]
                ]

{- | Decode the stored bytes with the ledger and read the datum view
back from the decoded output (Alonzo and later eras).
-}
ledgerDatum ::
    forall era.
    (AlonzoEraTxOut era) =>
    Proxy era ->
    TxOut ->
    View.DatumView
ledgerDatum _ stored =
    case decodeFullDecoder
            (Ledger.eraProtVerLow @era)
            "txout"
            decCBOR
            (BSL.fromStrict (unTxOut stored)) ::
            Either DecoderError (Ledger.TxOut era) of
        Left e -> error (show e)
        Right out' -> case out' ^. datumTxOutF of
            DatumHash sh -> View.DatumHash (hashToBytes (extractHash sh))
            Datum bd ->
                -- The inline bytes are the BinaryData's own
                -- (memoised) encoding, recovered by re-serialising
                -- the ledger's decoded datum.
                View.InlineDatum
                    (serialize' (Ledger.eraProtVerLow @era) (binaryDataToData bd))
            NoDatum -> View.NoDatum

-- * Per-era checks

checkBasic ::
    forall era.
    (Ledger.EraTxOut era, Ledger.Value era ~ Coin) =>
    Proxy era ->
    Expectation
checkBasic _ = do
    let out = mkBasicTxOut addr (inject (Coin 5)) :: Ledger.TxOut era
        stored = store @era out
    View.decodeTxOutView stored
        `shouldBe` Right (View.TxOutView [] View.NoDatum)

checkMaryAssets ::
    forall era.
    (Ledger.EraTxOut era, Ledger.Value era ~ Mary.MaryValue) =>
    Proxy era ->
    Expectation
checkMaryAssets _ = do
    let stored = store @era (maryOutOf @era)
    View.decodeTxOutView stored
        `shouldBe` Right
            (View.TxOutView (ledgerAssets (Proxy @era) stored) View.NoDatum)

checkDatumHash ::
    forall era.
    ( AlonzoEraTxOut era
    , Ledger.Value era ~ Mary.MaryValue
    ) =>
    Proxy era ->
    Expectation
checkDatumHash _ = do
    let out =
            (maryOutOf @era)
                & dataHashTxOutL
                    .~ SJust sampleDatumHash
        stored = store @era out
    View.decodeTxOutView stored
        `shouldBe` Right
            ( View.TxOutView
                (ledgerAssets (Proxy @era) stored)
                (ledgerDatum (Proxy @era) stored)
            )

checkInlineDatum ::
    forall era.
    ( BabbageEraTxOut era
    , Ledger.Value era ~ Mary.MaryValue
    ) =>
    Proxy era ->
    Expectation
checkInlineDatum _ = do
    let out =
            (maryOutOf @era)
                & datumTxOutL
                    .~ mkInlineDatum @era
        stored = store @era out
    View.decodeTxOutView stored
        `shouldBe` Right
            ( View.TxOutView
                (ledgerAssets (Proxy @era) stored)
                (ledgerDatum (Proxy @era) stored)
            )
    -- Inline bytes are a byte slice of the stored output.
    case View.decodeTxOutView stored of
        Right (View.TxOutView _ (View.InlineDatum bytes)) ->
            bytes `shouldSatisfy` (`BS.isInfixOf` unTxOut stored)
        other -> error ("expected inline datum, got " <> show other)

maryOutOf ::
    forall era.
    (Ledger.EraTxOut era, Ledger.Value era ~ Mary.MaryValue) =>
    Ledger.TxOut era
maryOutOf = mkBasicTxOut addr maryValue

isLeftView :: Either View.TxOutViewError View.TxOutView -> Bool
isLeftView = either (const True) (const False)

{- | A minimal map-form output whose value carries one zero-quantity
asset, hand-encoded from the grammar: address (4 bytes), value
@[100, {policy: {"zero!": 0}}]@.
-}
rawZeroQtyOutput :: ByteString
rawZeroQtyOutput =
    BS.pack $
        [0xA2, 0x00, 0x44]
            <> map fromIntegral (BS.unpack dummyAddr)
            <> [0x01, 0x82, 0x18, 0x64]
            <> [0xA1, 0x58, 0x1C]
            <> map fromIntegral (BS.unpack (BS.replicate 28 0x11))
            <> [0xA1, 0x45]
            <> map fromIntegral (BS.unpack "zero!")
            <> [0x00]

-- | Same shape with a negative quantity instead of zero.
rawNegativeQtyOutput :: ByteString
rawNegativeQtyOutput =
    BS.pack $
        [0xA2, 0x00, 0x44]
            <> map fromIntegral (BS.unpack dummyAddr)
            <> [0x01, 0x82, 0x18, 0x64]
            <> [0xA1, 0x58, 0x1C]
            <> map fromIntegral (BS.unpack (BS.replicate 28 0x11))
            <> [0xA1, 0x45]
            <> map fromIntegral (BS.unpack "zero!")
            <> [0x20]

-- | Four address bytes; the decoder treats addresses opaquely.
dummyAddr :: ByteString
dummyAddr = BS.pack [0xDE, 0xAD, 0xBE, 0xEF]

{- | Reference-script fixture: a ledger-built output with a native
script reference, cross-checked against the ledger's decoding of the
same stored bytes.
-}
checkScriptRef ::
    forall era.
    ( BabbageEraTxOut era
    , Ledger.Value era ~ Mary.MaryValue
    ) =>
    Proxy era ->
    Expectation
checkScriptRef _ = do
    let out =
            (maryOutOf @era)
                & referenceScriptTxOutL
                    .~ SJust
                        ( fromNativeScript
                            (RequireTimeStart (SlotNo 0))
                        )
        stored = store @era out
    View.decodeTxOutView stored
        `shouldBe` Right
            ( View.TxOutView
                (ledgerAssets (Proxy @era) stored)
                (ledgerDatum (Proxy @era) stored)
            )

-- * Integers of every CBOR width

{- | One generated output whose integers are written by hand, so the
width of every coin and quantity is chosen rather than left to the
ledger's encoder.
-}
data WidthOutput = WidthOutput
    { woForm :: Form
    , woCoin :: IntCode
    , woAssets :: [(ByteString, [(ByteString, IntCode)])]
    -- ^ Policies with their names and quantities; empty for a
    -- coin-only value.
    , woInlineDatum :: Bool
    -- ^ Map form only: carry an inline datum under key 2.
    }
    deriving stock (Show)

data Form = ArrayForm | MapForm
    deriving stock (Eq, Show)

-- | The argument width of an unsigned integer.
data Width = Inline | Bytes1 | Bytes2 | Bytes4 | Bytes8
    deriving stock (Eq, Show, Enum, Bounded)

-- | How one integer of the value is written.
data IntCode
    = UInt Width Integer
    | -- | A tag-2 bignum: an integer, but not an unsigned one.
      BigNum Integer
    | -- | A negative integer, minus the given magnitude.
      NegInt Integer
    deriving stock (Eq, Show)

{- | Both output forms, coin-only and with assets, every argument width
for the coin and for each quantity — mostly the value's canonical
width, sometimes a wider one, often a boundary value — and now and then
an integer that is not unsigned.
-}
genWidthOutput :: Gen WidthOutput
genWidthOutput = do
    form <- elements [ArrayForm, MapForm]
    coin <- genIntCode 0
    assets <- oneof [pure [], genAssets]
    inline <- case form of
        MapForm -> arbitrary
        ArrayForm -> pure False
    pure (WidthOutput form coin assets inline)
  where
    genAssets = do
        policies <- nonEmptySublist (map (BS.replicate 28) [0x11, 0x22, 0x33])
        traverse
            ( \p -> do
                names <- nonEmptySublist ["", "tok", BS.replicate 32 0xEE]
                (,) p <$> traverse (\n -> (,) n <$> genIntCode 1) names
            )
            policies
    nonEmptySublist xs = sublistOf xs `suchThat` (not . null)

{- | An integer at least @lo@ (zero-quantity entries are not ledger
outputs): canonical in a random width, a boundary value, a value
written wider than it needs, or not an unsigned integer at all.
-}
genIntCode :: Integer -> Gen IntCode
genIntCode lo =
    frequency
        [ (6, elements [minBound .. maxBound] >>= \w -> UInt w <$> choose (max lo (widthMin w), widthMax w))
        , (3, (\v -> UInt (canonicalWidth v) v) <$> elements (filter (>= lo) boundaries))
        , (2, elements [Bytes1 ..] >>= \w -> UInt w <$> choose (lo, widthMax (pred w)))
        , (1, BigNum <$> choose (max 1 lo, 2 ^ (64 :: Int) - 1))
        , (1, NegInt <$> choose (1, 24))
        ]
  where
    boundaries =
        [0, 23, 24, 255, 256, 65_535, 65_536, 2 ^ (32 :: Int) - 1, 2 ^ (32 :: Int), 2 ^ (64 :: Int) - 1]

widthMin, widthMax :: Width -> Integer
widthMin = \case
    Inline -> 0
    Bytes1 -> 24
    Bytes2 -> 256
    Bytes4 -> 65_536
    Bytes8 -> 2 ^ (32 :: Int)
widthMax = \case
    Inline -> 23
    Bytes1 -> 255
    Bytes2 -> 65_535
    Bytes4 -> 2 ^ (32 :: Int) - 1
    Bytes8 -> 2 ^ (64 :: Int) - 1

canonicalWidth :: Integer -> Width
canonicalWidth v = case filter (\w -> v <= widthMax w) [minBound .. maxBound] of
    w : _ -> w
    [] -> error ("not a 64-bit unsigned integer: " <> show v)

encodeIntCode :: IntCode -> [Word8]
encodeIntCode = \case
    UInt Inline v -> [fromInteger v]
    UInt Bytes1 v -> 0x18 : bigEndian 1 v
    UInt Bytes2 v -> 0x19 : bigEndian 2 v
    UInt Bytes4 v -> 0x1A : bigEndian 4 v
    UInt Bytes8 v -> 0x1B : bigEndian 8 v
    BigNum v -> 0xC2 : bytesItem (BS.pack (dropWhile (== 0) (bigEndian 8 v)))
    NegInt n -> [0x20 + fromInteger (n - 1)]

bigEndian :: Int -> Integer -> [Word8]
bigEndian n v = [fromInteger (v `div` (256 ^ i) `mod` 256) | i <- [n - 1, n - 2 .. 0]]

bytesItem :: ByteString -> [Word8]
bytesItem bs
    | len < 24 = (0x40 + fromIntegral len) : BS.unpack bs
    | otherwise = 0x58 : fromIntegral len : BS.unpack bs
  where
    len = BS.length bs

-- | The output bytes: an enterprise testnet address, then the value.
encodeWidthOutput :: WidthOutput -> ByteString
encodeWidthOutput WidthOutput{woForm, woCoin, woAssets, woInlineDatum} =
    BS.pack $ case woForm of
        ArrayForm -> 0x82 : address <> value
        MapForm
            | woInlineDatum -> [0xA3, 0x00] <> address <> [0x01] <> value <> datum
            | otherwise -> [0xA2, 0x00] <> address <> [0x01] <> value
  where
    address = bytesItem (BS.pack (0x60 : replicate 28 0xAA))
    value = case woAssets of
        [] -> encodeIntCode woCoin
        assets -> 0x82 : encodeIntCode woCoin <> multiAsset assets
    multiAsset assets =
        (0xA0 + fromIntegral (length assets))
            : concat
                [ bytesItem p
                    <> [0xA0 + fromIntegral (length names)]
                    <> concat [bytesItem n <> encodeIntCode q | (n, q) <- names]
                | (p, names) <- assets
                ]
    -- key 2: [1, 24(<<I 42>>)]
    datum = [0x02, 0x82, 0x01, 0xD8, 0x18] <> bytesItem (BS.pack [0x18, 0x2A])

{- | The decoder agrees with the ledger's own decoding of the same
bytes: both refuse them, or both read them, to the same assets
(compared as sets) and datum.
-}
agreesWithLedger :: WidthOutput -> Property
agreesWithLedger w =
    coverWidths w
        . cover 50 (isRight (ledgerView bytes)) "the ledger reads the output"
        $ case (ledgerView bytes, View.decodeTxOutView (TxOut bytes)) of
            (Left _, Left _) -> property True
            (Right expected, Right got) -> normalise got === normalise expected
            (Right expected, Left err) ->
                counterexample
                    ("the ledger reads " <> show expected <> ", the decoder fails: " <> show err)
                    False
            (Left err, Right got) ->
                counterexample
                    ("the ledger refuses (" <> show err <> "), the decoder reads " <> show got)
                    False
  where
    bytes = encodeWidthOutput w
    normalise v = v{View.tovAssets = sort (View.tovAssets v)}

ledgerView :: ByteString -> Either DecoderError View.TxOutView
ledgerView raw = do
    out <-
        decodeFullDecoder
            (Ledger.eraProtVerLow @ConwayEra)
            "txout"
            decCBOR
            (BSL.fromStrict raw) ::
            Either DecoderError (Ledger.TxOut ConwayEra)
    let Mary.MaryValue _ multiAsset = out ^. Ledger.valueTxOutL
        assets =
            [ (pol, nm, fromIntegral q)
            | (Mary.PolicyID (ScriptHash (UnsafeHash p)), Mary.AssetName n, q) <-
                Mary.flattenMultiAsset multiAsset
            , q > 0
            , Just pol <- [mkPolicyId (SBS.fromShort p)]
            , Just nm <- [mkAssetName (SBS.fromShort n)]
            ]
        datum = case out ^. datumTxOutF of
            DatumHash sh -> View.DatumHash (hashToBytes (extractHash sh))
            Datum bd -> View.InlineDatum (originalBytes bd)
            NoDatum -> View.NoDatum
    pure (View.TxOutView assets datum)

{- | Require every form × value kind × coin width, every quantity
width, the named boundaries and the non-unsigned integers to be
exercised.
-}
coverWidths :: WidthOutput -> Property -> Property
coverWidths WidthOutput{woForm, woCoin, woAssets} =
    foldr (.) id $
        [ cover 1 (woForm == form && null woAssets == coinOnly && coinWidth == Just width) $
            show form <> (if coinOnly then ", coin only, coin " else ", with assets, coin ") <> show width
        | form <- [ArrayForm, MapForm]
        , coinOnly <- [True, False]
        , width <- [minBound .. maxBound]
        ]
            <> [ cover 2 (Just width `elem` map widthOf quantities) ("a quantity in " <> show width)
               | width <- [minBound .. maxBound]
               ]
            <> [ cover 1 (woCoin == UInt (canonicalWidth v) v) ("coin " <> show v)
               | v <- [2 ^ (32 :: Int) - 1, 2 ^ (32 :: Int), 2 ^ (64 :: Int) - 1]
               ]
            <> [ cover 2 (isNothing coinWidth) "a coin that is not an unsigned integer"
               , cover 2 (Nothing `elem` map widthOf quantities) "a quantity that is not an unsigned integer"
               ]
  where
    coinWidth = widthOf woCoin
    quantities = [q | (_, names) <- woAssets, (_, q) <- names]
    widthOf = \case
        UInt width _ -> Just width
        _ -> Nothing
