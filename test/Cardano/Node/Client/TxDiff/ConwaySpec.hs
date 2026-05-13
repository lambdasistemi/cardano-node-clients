{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.TxDiff.ConwaySpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    dataToBinaryData,
 )
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    outputsTxBodyL,
    vldtTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
    serialize',
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (Script, eraProtVerLow)
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    diffConwayTx,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import PlutusCore.Data qualified as PLC

spec :: Spec
spec =
    describe "Conway transactions" $ do
        it "reports a Conway fee change at body.fee" $ do
            tx <- loadFixture sampleHash
            let validity = tx ^. bodyTxL . vldtTxBodyL
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            let tx' = tx & bodyTxL . feeTxBodyL .~ Coin 42
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    ( Map.fromList
                        [
                            ( "validityInterval"
                            , Just (validityIntervalJson validity)
                            )
                        ,
                            ( "outputs"
                            , Just (outputsJson outputs)
                            )
                        ]
                    )
                    ( Map.fromList
                        [
                            ( "fee"
                            , DiffNode
                                (DiffPath ["body", "fee"])
                                ( DiffChanged
                                    (coinJson (tx ^. bodyTxL . feeTxBodyL))
                                    (coinJson (Coin 42))
                                )
                            )
                        ]
                    )

        it "reports a Conway validity change at body.validityInterval.invalidHereafter" $ do
            tx <- loadFixture sampleHash
            let oldValidity = tx ^. bodyTxL . vldtTxBodyL
                outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
                newValidity =
                    oldValidity
                        { invalidHereafter =
                            differentSlotBound (invalidHereafter oldValidity)
                        }
                tx' = tx & bodyTxL . vldtTxBodyL .~ newValidity
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    ( Map.fromList
                        [
                            ( "fee"
                            , Just (coinJson (tx ^. bodyTxL . feeTxBodyL))
                            )
                        ,
                            ( "outputs"
                            , Just (outputsJson outputs)
                            )
                        ]
                    )
                    ( Map.fromList
                        [
                            ( "validityInterval"
                            , DiffNode
                                (DiffPath ["body", "validityInterval"])
                                ( DiffObject
                                    ( Map.fromList
                                        [
                                            ( "invalidBefore"
                                            , Just $
                                                strictMaybeSlotJson $
                                                    invalidBefore oldValidity
                                            )
                                        ]
                                    )
                                    ( Map.fromList
                                        [
                                            ( "invalidHereafter"
                                            , DiffNode
                                                ( DiffPath
                                                    [ "body"
                                                    , "validityInterval"
                                                    , "invalidHereafter"
                                                    ]
                                                )
                                                ( DiffChanged
                                                    ( strictMaybeSlotJson $
                                                        invalidHereafter oldValidity
                                                    )
                                                    ( strictMaybeSlotJson $
                                                        invalidHereafter newValidity
                                                    )
                                                )
                                            )
                                        ]
                                    )
                                    Map.empty
                                    Map.empty
                                )
                            )
                        ]
                    )

        it "reports a Conway output coin change at body.outputs.0.coin" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                [] ->
                    expectationFailure "fixture has no outputs"
                firstOutput : otherOutputs -> do
                    let changedOutput =
                            firstOutput & coinTxOutL .~ Coin 42
                        tx' =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        (changedOutput : otherOutputs)
                    diffConwayTx tx tx'
                        `shouldBe` bodyDiff
                            ( Map.fromList
                                [
                                    ( "fee"
                                    , Just (coinJson (tx ^. bodyTxL . feeTxBodyL))
                                    )
                                ,
                                    ( "validityInterval"
                                    , Just $
                                        validityIntervalJson $
                                            tx ^. bodyTxL . vldtTxBodyL
                                    )
                                ]
                            )
                            ( Map.singleton
                                "outputs"
                                ( DiffNode
                                    (DiffPath ["body", "outputs"])
                                    ( DiffArray
                                        ( indexedOutputSummaries otherOutputs
                                        )
                                        [
                                            ( 0
                                            , DiffNode
                                                ( DiffPath
                                                    ["body", "outputs", "0"]
                                                )
                                                ( DiffObject
                                                    ( outputCommonExcept
                                                        ["coin"]
                                                        firstOutput
                                                    )
                                                    ( Map.singleton
                                                        "coin"
                                                        ( DiffNode
                                                            ( DiffPath
                                                                [ "body"
                                                                , "outputs"
                                                                , "0"
                                                                , "coin"
                                                                ]
                                                            )
                                                            ( DiffChanged
                                                                ( coinJson $
                                                                    firstOutput
                                                                        ^. coinTxOutL
                                                                )
                                                                (coinJson (Coin 42))
                                                            )
                                                        )
                                                    )
                                                    Map.empty
                                                    Map.empty
                                                )
                                            )
                                        ]
                                        []
                                        []
                                    )
                                )
                            )

        it "reports a Conway output address change at body.outputs.0.address" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                firstOutput : secondOutput : otherOutputs -> do
                    let newAddress = secondOutput ^. addrTxOutL
                        oldAddress = firstOutput ^. addrTxOutL
                    oldAddress `shouldNotBe` newAddress
                    let changedOutput =
                            firstOutput & addrTxOutL .~ newAddress
                        tx' =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        ( changedOutput
                                            : secondOutput
                                            : otherOutputs
                                        )
                    diffConwayTx tx tx'
                        `shouldBe` bodyDiff
                            ( Map.fromList
                                [
                                    ( "fee"
                                    , Just (coinJson (tx ^. bodyTxL . feeTxBodyL))
                                    )
                                ,
                                    ( "validityInterval"
                                    , Just $
                                        validityIntervalJson $
                                            tx ^. bodyTxL . vldtTxBodyL
                                    )
                                ]
                            )
                            ( Map.singleton
                                "outputs"
                                ( DiffNode
                                    (DiffPath ["body", "outputs"])
                                    ( DiffArray
                                        ( indexedOutputSummaries
                                            (secondOutput : otherOutputs)
                                        )
                                        [
                                            ( 0
                                            , DiffNode
                                                ( DiffPath
                                                    ["body", "outputs", "0"]
                                                )
                                                ( DiffObject
                                                    ( outputCommonExcept
                                                        ["address"]
                                                        firstOutput
                                                    )
                                                    ( Map.singleton
                                                        "address"
                                                        ( DiffNode
                                                            ( DiffPath
                                                                [ "body"
                                                                , "outputs"
                                                                , "0"
                                                                , "address"
                                                                ]
                                                            )
                                                            ( DiffChanged
                                                                ( addressJson
                                                                    oldAddress
                                                                )
                                                                ( addressJson
                                                                    newAddress
                                                                )
                                                            )
                                                        )
                                                    )
                                                    Map.empty
                                                    Map.empty
                                                )
                                            )
                                        ]
                                        []
                                        []
                                    )
                                )
                            )
                _ ->
                    expectationFailure "fixture has fewer than two outputs"

        it "reports a Conway output datum change at body.outputs.0.datum" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                [] ->
                    expectationFailure "fixture has no outputs"
                firstOutput : otherOutputs -> do
                    let oldDatum = firstOutput ^. datumTxOutL
                        newDatum = inlineIntegerDatum 42
                    oldDatum `shouldNotBe` newDatum
                    let changedOutput =
                            firstOutput & datumTxOutL .~ newDatum
                        tx' =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        (changedOutput : otherOutputs)
                    diffConwayTx tx tx'
                        `shouldBe` bodyDiff
                            ( Map.fromList
                                [
                                    ( "fee"
                                    , Just (coinJson (tx ^. bodyTxL . feeTxBodyL))
                                    )
                                ,
                                    ( "validityInterval"
                                    , Just $
                                        validityIntervalJson $
                                            tx ^. bodyTxL . vldtTxBodyL
                                    )
                                ]
                            )
                            ( Map.singleton
                                "outputs"
                                ( DiffNode
                                    (DiffPath ["body", "outputs"])
                                    ( DiffArray
                                        ( indexedOutputSummaries otherOutputs
                                        )
                                        [
                                            ( 0
                                            , DiffNode
                                                ( DiffPath
                                                    ["body", "outputs", "0"]
                                                )
                                                ( DiffObject
                                                    ( outputCommonExcept
                                                        ["datum"]
                                                        firstOutput
                                                    )
                                                    ( Map.singleton
                                                        "datum"
                                                        ( DiffNode
                                                            ( DiffPath
                                                                [ "body"
                                                                , "outputs"
                                                                , "0"
                                                                , "datum"
                                                                ]
                                                            )
                                                            ( DiffChanged
                                                                ( datumJson
                                                                    oldDatum
                                                                )
                                                                ( datumJson
                                                                    newDatum
                                                                )
                                                            )
                                                        )
                                                    )
                                                    Map.empty
                                                    Map.empty
                                                )
                                            )
                                        ]
                                        []
                                        []
                                    )
                                )
                            )

        it "reports a Conway output reference script change at body.outputs.0.referenceScript" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                [] ->
                    expectationFailure "fixture has no outputs"
                firstOutput : otherOutputs -> do
                    let oldReferenceScript =
                            firstOutput ^. referenceScriptTxOutL
                        newReferenceScript =
                            SJust alwaysTrueScript
                    oldReferenceScript `shouldNotBe` newReferenceScript
                    let changedOutput =
                            firstOutput
                                & referenceScriptTxOutL
                                    .~ newReferenceScript
                        tx' =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        (changedOutput : otherOutputs)
                    diffConwayTx tx tx'
                        `shouldBe` bodyDiff
                            ( Map.fromList
                                [
                                    ( "fee"
                                    , Just (coinJson (tx ^. bodyTxL . feeTxBodyL))
                                    )
                                ,
                                    ( "validityInterval"
                                    , Just $
                                        validityIntervalJson $
                                            tx ^. bodyTxL . vldtTxBodyL
                                    )
                                ]
                            )
                            ( Map.singleton
                                "outputs"
                                ( DiffNode
                                    (DiffPath ["body", "outputs"])
                                    ( DiffArray
                                        ( indexedOutputSummaries otherOutputs
                                        )
                                        [
                                            ( 0
                                            , DiffNode
                                                ( DiffPath
                                                    ["body", "outputs", "0"]
                                                )
                                                ( DiffObject
                                                    ( outputCommonExcept
                                                        ["referenceScript"]
                                                        firstOutput
                                                    )
                                                    ( Map.singleton
                                                        "referenceScript"
                                                        ( DiffNode
                                                            ( DiffPath
                                                                [ "body"
                                                                , "outputs"
                                                                , "0"
                                                                , "referenceScript"
                                                                ]
                                                            )
                                                            ( DiffChanged
                                                                ( referenceScriptJson
                                                                    oldReferenceScript
                                                                )
                                                                ( referenceScriptJson
                                                                    newReferenceScript
                                                                )
                                                            )
                                                        )
                                                    )
                                                    Map.empty
                                                    Map.empty
                                                )
                                            )
                                        ]
                                        []
                                        []
                                    )
                                )
                            )

rootPath :: DiffPath
rootPath =
    DiffPath []

bodyDiff :: Map.Map Text (Maybe Aeson.Value) -> Map.Map Text DiffNode -> DiffNode
bodyDiff common changed =
    DiffNode
        rootPath
        ( DiffObject
            Map.empty
            ( Map.singleton
                "body"
                ( DiffNode
                    (DiffPath ["body"])
                    (DiffObject common changed Map.empty Map.empty)
                )
            )
            Map.empty
            Map.empty
        )

loadFixture :: String -> IO ConwayTx
loadFixture hash = do
    hex <- Text.strip . Text.pack <$> readFile (fixturePath hash)
    case decodeFullAnnotatorFromHexText
        (natVersion @11)
        "tx-diff fixture"
        (decCBOR :: forall s. Decoder s (Annotator ConwayTx))
        hex of
        Right tx ->
            pure tx
        Left err ->
            expectationFailure ("failed to decode fixture: " <> show err)
                >> fail "fixture decode failed"

fixturePath :: String -> FilePath
fixturePath hash =
    "test/fixtures/mainnet-txbuild/" <> hash <> ".cbor.hex"

sampleHash :: String
sampleHash =
    "789f9a1393e3c9eacd19582ebb1b02b777696c8ddcedda2d8752cb5723c42ef6"

coinJson :: Coin -> Aeson.Value
coinJson (Coin lovelace) =
    Aeson.object ["lovelace" .= lovelace]

outputsJson :: [TxOut ConwayEra] -> Aeson.Value
outputsJson outputs =
    Aeson.toJSON (map outputJson outputs)

outputJson :: TxOut ConwayEra -> Aeson.Value
outputJson output =
    Aeson.object
        [ "address" .= addressJson (output ^. addrTxOutL)
        , "coin" .= coinJson (output ^. coinTxOutL)
        , "datum" .= datumJson (output ^. datumTxOutL)
        , "referenceScript"
            .= referenceScriptJson (output ^. referenceScriptTxOutL)
        ]

outputCommonExcept ::
    [Text] ->
    TxOut ConwayEra ->
    Map.Map Text (Maybe Aeson.Value)
outputCommonExcept omitted output =
    Map.fromList
        [ (field, Just value)
        | (field, value) <- outputFieldValues output
        , field `notElem` omitted
        ]

outputFieldValues :: TxOut ConwayEra -> [(Text, Aeson.Value)]
outputFieldValues output =
    [
        ( "address"
        , addressJson (output ^. addrTxOutL)
        )
    ,
        ( "coin"
        , coinJson (output ^. coinTxOutL)
        )
    ,
        ( "datum"
        , datumJson (output ^. datumTxOutL)
        )
    ,
        ( "referenceScript"
        , referenceScriptJson (output ^. referenceScriptTxOutL)
        )
    ]

addressJson :: Addr -> Aeson.Value
addressJson address =
    Aeson.object ["bytes" .= hexText (serialiseAddr address)]

hexText :: ByteString -> Text
hexText =
    Text.decodeUtf8 . Base16.encode

datumJson :: Datum ConwayEra -> Aeson.Value
datumJson datum =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) datum)
        ]

inlineIntegerDatum :: Integer -> Datum ConwayEra
inlineIntegerDatum value =
    Datum $
        dataToBinaryData (Data (PLC.I value) :: Data ConwayEra)

referenceScriptJson :: StrictMaybe (Script ConwayEra) -> Aeson.Value
referenceScriptJson SNothing =
    Aeson.Null
referenceScriptJson (SJust script) =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) script)
        ]

alwaysTrueHex :: BS8.ByteString
alwaysTrueHex =
    "58d501010029800aba2aba1aab9eaab9dab9a48888966002646465\
    \300130053754003300700398038012444b30013370e9000001c4c\
    \9289bae300a3009375400915980099b874800800e2646644944c0\
    \2c004c02cc030004c024dd5002456600266e1d200400389925130\
    \0a3009375400915980099b874801800e2646644944dd698058009\
    \805980600098049baa0048acc004cdc3a40100071324a26014601\
    \26ea80122646644944dd698058009805980600098049baa004401\
    \c8039007200e401c3006300700130060013003375400d149a26ca\
    \c8009"

alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            either error id $
                Base16.decode (BS8.filter (/= '\n') alwaysTrueHex)
        plutus = Plutus @PlutusV3 (PlutusBinary (SBS.toShort bytes))
     in maybe
            (error "alwaysTrueScript: mkPlutusScript")
            fromPlutusScript
            (mkPlutusScript plutus)

validityIntervalJson :: ValidityInterval -> Aeson.Value
validityIntervalJson validity =
    Aeson.object
        [ "invalidBefore" .= strictMaybeSlotJson (invalidBefore validity)
        , "invalidHereafter"
            .= strictMaybeSlotJson (invalidHereafter validity)
        ]

strictMaybeSlotJson :: StrictMaybe SlotNo -> Aeson.Value
strictMaybeSlotJson SNothing =
    Aeson.Null
strictMaybeSlotJson (SJust (SlotNo slot)) =
    Aeson.toJSON slot

differentSlotBound :: StrictMaybe SlotNo -> StrictMaybe SlotNo
differentSlotBound (SJust (SlotNo 42)) =
    SJust (SlotNo 43)
differentSlotBound _ =
    SJust (SlotNo 42)

indexedOutputSummaries :: [TxOut ConwayEra] -> [(Int, Maybe Aeson.Value)]
indexedOutputSummaries outputs =
    [ (index, Just (outputJson output))
    | (index, output) <- zip [1 ..] outputs
    ]
