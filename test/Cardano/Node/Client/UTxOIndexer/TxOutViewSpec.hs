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
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Proxy (Proxy (..))
import Data.Word (Word64)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (
    Expectation,
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
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
