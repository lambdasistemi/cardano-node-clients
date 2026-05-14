{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.TxDiff.ConwaySpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Crypto.Hash (hashFromStringAsHex, hashToBytes)
import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr,
    Withdrawals (..),
    serialiseAddr,
 )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (
    AsIx (..),
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..))
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    dataToBinaryData,
    hashData,
 )
import Cardano.Ledger.Api.Tx (
    addrTxWitsL,
    bodyTxL,
    bootAddrTxWitsL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    totalCollateralTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    datsTxWitsL,
    rdmrsTxWitsL,
    scriptTxWitsL,
    witVKeyHash,
 )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..), TxIx (..))
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
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, eraProtVerLow, hashScript)
import Cardano.Ledger.Credential (Credential (KeyHashObj))
import Cardano.Ledger.Hashes (
    DataHash,
    ScriptHash (..),
    extractHash,
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Guard, Witness),
    WitVKey (..),
    hashKey,
 )
import Cardano.Ledger.Keys.Bootstrap (
    BootstrapWitness (..),
    ChainCode (..),
 )
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    TxDiffOptions (..),
    decodeConwayTxInput,
    defaultTxDiffOptions,
    diffConwayTx,
    diffConwayTxWith,
    renderConwayTxInputDiff,
    renderDiffNodeHuman,
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint (..),
    BlueprintArgument (..),
    BlueprintPreamble (..),
    BlueprintSchema (..),
    BlueprintSchemaKind (..),
    BlueprintValidator (..),
    blueprintDataDecoder,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import PlutusCore.Data qualified as PLC

spec :: Spec
spec =
    describe "Conway transactions" $ do
        it "decodes tx input from CBOR hex, raw CBOR, and cardano-cli JSON envelope" $ do
            expected <- loadFixture sampleHash
            hex <- loadFixtureHex sampleHash
            raw <- decodeFixtureHex hex
            let envelope =
                    LBS.toStrict $
                        Aeson.encode $
                            Aeson.object
                                [ "type" .= ("Tx ConwayEra" :: Text)
                                , "description" .= ("fixture" :: Text)
                                , "cborHex" .= hex
                                ]
            decodeConwayTxInput (Text.encodeUtf8 hex)
                `shouldBe` Right expected
            decodeConwayTxInput raw `shouldBe` Right expected
            decodeConwayTxInput envelope `shouldBe` Right expected

        it "renders a human diff from two encoded transaction inputs" $ do
            tx <- loadFixture sampleHash
            hex <- loadFixtureHex sampleHash
            let tx' = tx & bodyTxL . feeTxBodyL .~ Coin 42
                rendered =
                    renderConwayTxInputDiff
                        (Text.encodeUtf8 hex)
                        (serialize' (eraProtVerLow @ConwayEra) tx')
            case rendered of
                Left err ->
                    expectationFailure ("failed to render tx diff: " <> show err)
                Right output -> do
                    output `shouldSatisfy` Text.isInfixOf "`- fee"
                    output
                        `shouldSatisfy` Text.isInfixOf
                            "B: 0.000042 ADA (42 lovelace)"

        it "reports a Conway fee change at body.fee" $ do
            tx <- loadFixture sampleHash
            let tx' = tx & bodyTxL . feeTxBodyL .~ Coin 42
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["fee"] tx)
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
                newValidity =
                    oldValidity
                        { invalidHereafter =
                            differentSlotBound (invalidHereafter oldValidity)
                        }
                tx' = tx & bodyTxL . vldtTxBodyL .~ newValidity
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["validityInterval"] tx)
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
                            (bodyCommonExcept ["outputs"] tx)
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
                            (bodyCommonExcept ["outputs"] tx)
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
                            (bodyCommonExcept ["outputs"] tx)
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
                                                                (Aeson.Number 42)
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
                            (bodyCommonExcept ["outputs"] tx)
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

        it "reports a Conway input change at body.inputs.0" $ do
            tx <- loadFixture sampleHash
            let oldInput = mkTxIn 1
                newInput = mkTxIn 2
                txA =
                    tx
                        & bodyTxL
                            . inputsTxBodyL
                            .~ Set.singleton oldInput
                txB =
                    tx
                        & bodyTxL
                            . inputsTxBodyL
                            .~ Set.singleton newInput
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["inputs"] txA)
                    ( Map.singleton
                        "inputs"
                        ( DiffNode
                            (DiffPath ["body", "inputs"])
                            ( DiffArray
                                []
                                [
                                    ( 0
                                    , DiffNode
                                        (DiffPath ["body", "inputs", "0"])
                                        ( DiffChanged
                                            (txInJson oldInput)
                                            (txInJson newInput)
                                        )
                                    )
                                ]
                                []
                                []
                            )
                        )
                    )

        it "reports a Conway reference input change at body.referenceInputs.0" $ do
            tx <- loadFixture sampleHash
            let oldInput = mkTxIn 1
                newInput = mkTxIn 2
                txA =
                    tx
                        & bodyTxL
                            . referenceInputsTxBodyL
                            .~ Set.singleton oldInput
                txB =
                    tx
                        & bodyTxL
                            . referenceInputsTxBodyL
                            .~ Set.singleton newInput
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["referenceInputs"] txA)
                    ( Map.singleton
                        "referenceInputs"
                        ( DiffNode
                            (DiffPath ["body", "referenceInputs"])
                            ( DiffArray
                                []
                                [
                                    ( 0
                                    , DiffNode
                                        ( DiffPath
                                            [ "body"
                                            , "referenceInputs"
                                            , "0"
                                            ]
                                        )
                                        ( DiffChanged
                                            (txInJson oldInput)
                                            (txInJson newInput)
                                        )
                                    )
                                ]
                                []
                                []
                            )
                        )
                    )

        it "reports a Conway collateral input change at body.collateralInputs.0" $ do
            tx <- loadFixture sampleHash
            let oldInput = mkTxIn 1
                newInput = mkTxIn 2
                txA =
                    tx
                        & bodyTxL
                            . collateralInputsTxBodyL
                            .~ Set.singleton oldInput
                txB =
                    tx
                        & bodyTxL
                            . collateralInputsTxBodyL
                            .~ Set.singleton newInput
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["collateralInputs"] txA)
                    ( Map.singleton
                        "collateralInputs"
                        ( DiffNode
                            (DiffPath ["body", "collateralInputs"])
                            ( DiffArray
                                []
                                [
                                    ( 0
                                    , DiffNode
                                        ( DiffPath
                                            [ "body"
                                            , "collateralInputs"
                                            , "0"
                                            ]
                                        )
                                        ( DiffChanged
                                            (txInJson oldInput)
                                            (txInJson newInput)
                                        )
                                    )
                                ]
                                []
                                []
                            )
                        )
                    )

        it "reports a Conway total collateral change at body.totalCollateral" $ do
            tx <- loadFixture sampleHash
            let oldTotalCollateral =
                    tx ^. bodyTxL . totalCollateralTxBodyL
                newTotalCollateral =
                    SJust (Coin 42)
            oldTotalCollateral `shouldNotBe` newTotalCollateral
            let tx' =
                    tx
                        & bodyTxL
                            . totalCollateralTxBodyL
                            .~ newTotalCollateral
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["totalCollateral"] tx)
                    ( Map.singleton
                        "totalCollateral"
                        ( DiffNode
                            (DiffPath ["body", "totalCollateral"])
                            ( DiffChanged
                                (strictMaybeCoinJson oldTotalCollateral)
                                (strictMaybeCoinJson newTotalCollateral)
                            )
                        )
                    )

        it "reports a Conway required signer change at body.requiredSigners.0" $ do
            tx <- loadFixture sampleHash
            let oldSigner = mkWitnessKeyHash 1
                newSigner = mkWitnessKeyHash 2
                txA =
                    tx
                        & bodyTxL
                            . reqSignerHashesTxBodyL
                            .~ Set.singleton oldSigner
                txB =
                    tx
                        & bodyTxL
                            . reqSignerHashesTxBodyL
                            .~ Set.singleton newSigner
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["requiredSigners"] txA)
                    ( Map.singleton
                        "requiredSigners"
                        ( DiffNode
                            (DiffPath ["body", "requiredSigners"])
                            ( DiffArray
                                []
                                [
                                    ( 0
                                    , DiffNode
                                        ( DiffPath
                                            [ "body"
                                            , "requiredSigners"
                                            , "0"
                                            ]
                                        )
                                        ( DiffChanged
                                            (keyHashJson oldSigner)
                                            (keyHashJson newSigner)
                                        )
                                    )
                                ]
                                []
                                []
                            )
                        )
                    )

        it "reports a Conway withdrawal coin change keyed by reward account" $ do
            tx <- loadFixture sampleHash
            let rewardAccount = mkRewardAccount 1
                oldCoin = Coin 1_000_000
                newCoin = Coin 2_000_000
                txA =
                    tx
                        & bodyTxL
                            . withdrawalsTxBodyL
                            .~ Withdrawals (Map.singleton rewardAccount oldCoin)
                txB =
                    tx
                        & bodyTxL
                            . withdrawalsTxBodyL
                            .~ Withdrawals (Map.singleton rewardAccount newCoin)
                rewardAccountPath = rewardAccountKey rewardAccount
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["withdrawals"] txA)
                    ( Map.singleton
                        "withdrawals"
                        ( DiffNode
                            (DiffPath ["body", "withdrawals"])
                            ( DiffObject
                                Map.empty
                                ( Map.singleton
                                    rewardAccountPath
                                    ( DiffNode
                                        ( DiffPath
                                            [ "body"
                                            , "withdrawals"
                                            , rewardAccountPath
                                            ]
                                        )
                                        ( DiffChanged
                                            (coinJson oldCoin)
                                            (coinJson newCoin)
                                        )
                                    )
                                )
                                Map.empty
                                Map.empty
                            )
                        )
                    )

        it "reports a Conway mint quantity change keyed by policy and asset" $ do
            tx <- loadFixture sampleHash
            let policyId = mkPolicyId 1
                assetName = AssetName (SBS.pack [0xCA, 0xFE])
                oldQuantity = 50
                newQuantity = 60
                txA =
                    tx
                        & bodyTxL
                            . mintTxBodyL
                            .~ MultiAsset
                                ( Map.singleton
                                    policyId
                                    (Map.singleton assetName oldQuantity)
                                )
                txB =
                    tx
                        & bodyTxL
                            . mintTxBodyL
                            .~ MultiAsset
                                ( Map.singleton
                                    policyId
                                    (Map.singleton assetName newQuantity)
                                )
                policyPath = policyIdKey policyId
                assetPath = assetNameKey assetName
            diffConwayTx txA txB
                `shouldBe` bodyDiff
                    (bodyCommonExcept ["mint"] txA)
                    ( Map.singleton
                        "mint"
                        ( DiffNode
                            (DiffPath ["body", "mint"])
                            ( DiffObject
                                Map.empty
                                ( Map.singleton
                                    policyPath
                                    ( DiffNode
                                        (DiffPath ["body", "mint", policyPath])
                                        ( DiffObject
                                            Map.empty
                                            ( Map.singleton
                                                assetPath
                                                ( DiffNode
                                                    ( DiffPath
                                                        [ "body"
                                                        , "mint"
                                                        , policyPath
                                                        , assetPath
                                                        ]
                                                    )
                                                    ( DiffChanged
                                                        ( Aeson.toJSON
                                                            oldQuantity
                                                        )
                                                        ( Aeson.toJSON
                                                            newQuantity
                                                        )
                                                    )
                                                )
                                            )
                                            Map.empty
                                            Map.empty
                                        )
                                    )
                                )
                                Map.empty
                                Map.empty
                            )
                        )
                    )

        it "reports an opt-in Conway witness script insertion keyed by script hash" $ do
            tx <- loadFixture sampleHash
            let scriptHash = hashScript alwaysTrueScript
            let txA =
                    tx
                        & witsTxL
                            . scriptTxWitsL
                            .~ Map.empty
                txB =
                    tx
                        & witsTxL
                            . scriptTxWitsL
                            .~ Map.singleton scriptHash alwaysTrueScript
                options =
                    defaultTxDiffOptions
                        { txDiffIncludeWitnesses = True
                        }
                scriptPath = scriptHashKey scriptHash
            diffConwayTxWith options txA txB
                `shouldBe` DiffNode
                    rootPath
                    ( DiffObject
                        (Map.singleton "body" Nothing)
                        ( Map.singleton
                            "witnesses"
                            ( DiffNode
                                (DiffPath ["witnesses"])
                                ( DiffObject
                                    (witnessCommonExcept ["scripts"] txA)
                                    ( Map.singleton
                                        "scripts"
                                        ( DiffNode
                                            ( DiffPath
                                                ["witnesses", "scripts"]
                                            )
                                            ( DiffObject
                                                Map.empty
                                                Map.empty
                                                Map.empty
                                                ( Map.singleton
                                                    scriptPath
                                                    ( scriptJson
                                                        alwaysTrueScript
                                                    )
                                                )
                                            )
                                        )
                                    )
                                    Map.empty
                                    Map.empty
                                )
                            )
                        )
                        Map.empty
                        Map.empty
                    )

        it "reports an opt-in Conway witness datum insertion keyed by data hash" $ do
            tx <- loadFixture sampleHash
            let datumData = integerData 42
                datumHash = hashData datumData
                txA =
                    tx
                        & witsTxL
                            . datsTxWitsL
                            .~ TxDats Map.empty
                txB =
                    tx
                        & witsTxL
                            . datsTxWitsL
                            .~ TxDats (Map.singleton datumHash datumData)
                options =
                    defaultTxDiffOptions
                        { txDiffIncludeWitnesses = True
                        }
                datumPath = dataHashKey datumHash
            diffConwayTxWith options txA txB
                `shouldBe` DiffNode
                    rootPath
                    ( DiffObject
                        (Map.singleton "body" Nothing)
                        ( Map.singleton
                            "witnesses"
                            ( DiffNode
                                (DiffPath ["witnesses"])
                                ( DiffObject
                                    (witnessCommonExcept ["datums"] txA)
                                    ( Map.singleton
                                        "datums"
                                        ( DiffNode
                                            ( DiffPath
                                                ["witnesses", "datums"]
                                            )
                                            ( DiffObject
                                                Map.empty
                                                Map.empty
                                                Map.empty
                                                ( Map.singleton
                                                    datumPath
                                                    (Aeson.Number 42)
                                                )
                                            )
                                        )
                                    )
                                    Map.empty
                                    Map.empty
                                )
                            )
                        )
                        Map.empty
                        Map.empty
                    )

        it "reports an opt-in Conway redeemer data change keyed by purpose and index" $ do
            tx <- loadFixture sampleHash
            let purpose = ConwaySpending (AsIx 0)
                oldRedeemer = integerData 1
                newRedeemer = integerData 2
                exUnits = ExUnits 1000 10000
                txA =
                    tx
                        & witsTxL
                            . rdmrsTxWitsL
                            .~ Redeemers
                                (Map.singleton purpose (oldRedeemer, exUnits))
                txB =
                    tx
                        & witsTxL
                            . rdmrsTxWitsL
                            .~ Redeemers
                                (Map.singleton purpose (newRedeemer, exUnits))
                options =
                    defaultTxDiffOptions
                        { txDiffIncludeWitnesses = True
                        }
                purposePath = redeemerPurposeKey purpose
            diffConwayTxWith options txA txB
                `shouldBe` DiffNode
                    rootPath
                    ( DiffObject
                        (Map.singleton "body" Nothing)
                        ( Map.singleton
                            "witnesses"
                            ( DiffNode
                                (DiffPath ["witnesses"])
                                ( DiffObject
                                    (witnessCommonExcept ["redeemers"] txA)
                                    ( Map.singleton
                                        "redeemers"
                                        ( DiffNode
                                            ( DiffPath
                                                ["witnesses", "redeemers"]
                                            )
                                            ( DiffObject
                                                Map.empty
                                                ( Map.singleton
                                                    purposePath
                                                    ( DiffNode
                                                        ( DiffPath
                                                            [ "witnesses"
                                                            , "redeemers"
                                                            , purposePath
                                                            ]
                                                        )
                                                        ( DiffObject
                                                            ( Map.singleton
                                                                "exUnits"
                                                                ( Just $
                                                                    exUnitsJson
                                                                        exUnits
                                                                )
                                                            )
                                                            ( Map.singleton
                                                                "data"
                                                                ( DiffNode
                                                                    ( DiffPath
                                                                        [ "witnesses"
                                                                        , "redeemers"
                                                                        , purposePath
                                                                        , "data"
                                                                        ]
                                                                    )
                                                                    ( DiffChanged
                                                                        (Aeson.Number 1)
                                                                        (Aeson.Number 2)
                                                                    )
                                                                )
                                                            )
                                                            Map.empty
                                                            Map.empty
                                                        )
                                                    )
                                                )
                                                Map.empty
                                                Map.empty
                                            )
                                        )
                                    )
                                    Map.empty
                                    Map.empty
                                )
                            )
                        )
                        Map.empty
                        Map.empty
                    )

        it "uses a matched blueprint decoder to descend into inline output datum fields" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                [] ->
                    expectationFailure "fixture has no outputs"
                firstOutput : otherOutputs -> do
                    let oldDatum = inlineOrderDatum 42
                        newDatum = inlineOrderDatum 43
                        txA =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        ( ( firstOutput
                                                & datumTxOutL .~ oldDatum
                                          )
                                            : otherOutputs
                                        )
                        txB =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        ( ( firstOutput
                                                & datumTxOutL .~ newDatum
                                          )
                                            : otherOutputs
                                        )
                        options =
                            defaultTxDiffOptions
                                { txDiffDecodeData =
                                    Just (blueprintDataDecoder [orderBlueprint])
                                }
                        output = renderDiffNodeHuman (diffConwayTxWith options txA txB)
                    output
                        `shouldSatisfy` Text.isInfixOf
                            "amount: A: 42 | B: 43"

        it "descends into inline output datum as raw Plutus data without a matching blueprint" $ do
            tx <- loadFixture sampleHash
            let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
            case outputs of
                [] ->
                    expectationFailure "fixture has no outputs"
                firstOutput : otherOutputs -> do
                    let oldDatum = inlineOrderDatum 42
                        newDatum = inlineOrderDatum 43
                        txA =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        ( ( firstOutput
                                                & datumTxOutL .~ oldDatum
                                          )
                                            : otherOutputs
                                        )
                        txB =
                            tx
                                & bodyTxL
                                    . outputsTxBodyL
                                    .~ StrictSeq.fromList
                                        ( ( firstOutput
                                                & datumTxOutL .~ newDatum
                                          )
                                            : otherOutputs
                                        )
                        output =
                            renderDiffNodeHuman
                                (diffConwayTxWith defaultTxDiffOptions txA txB)
                    output `shouldSatisfy` Text.isInfixOf "`- datum"
                    output `shouldSatisfy` Text.isInfixOf "`- fields"
                    output `shouldSatisfy` Text.isInfixOf "0: A: 42 | B: 43"
                    output `shouldNotSatisfy` Text.isInfixOf "cbor:"

        it "uses a matched blueprint decoder to descend into redeemer data fields" $ do
            tx <- loadFixture sampleHash
            let purpose = ConwaySpending (AsIx 0)
                oldRedeemer = orderRedeemerData 42
                newRedeemer = orderRedeemerData 43
                exUnits = ExUnits 1000 10000
                txA =
                    tx
                        & witsTxL
                            . rdmrsTxWitsL
                            .~ Redeemers
                                (Map.singleton purpose (oldRedeemer, exUnits))
                txB =
                    tx
                        & witsTxL
                            . rdmrsTxWitsL
                            .~ Redeemers
                                (Map.singleton purpose (newRedeemer, exUnits))
                options =
                    defaultTxDiffOptions
                        { txDiffIncludeWitnesses = True
                        , txDiffDecodeData =
                            Just (blueprintDataDecoder [orderBlueprint])
                        }
                output = renderDiffNodeHuman (diffConwayTxWith options txA txB)
            output
                `shouldSatisfy` Text.isInfixOf
                    "amount: A: 42 | B: 43"
            output
                `shouldNotSatisfy` Text.isInfixOf "cbor:"

        it "reports an opt-in Conway key witness deletion keyed by key hash" $ do
            tx <- loadFixture sampleHash
            case Set.toAscList (tx ^. witsTxL . addrTxWitsL) of
                [] ->
                    expectationFailure "fixture has no key witnesses"
                firstWitness : _ -> do
                    let txA =
                            tx
                                & witsTxL
                                    . addrTxWitsL
                                    .~ Set.singleton firstWitness
                        txB =
                            tx
                                & witsTxL
                                    . addrTxWitsL
                                    .~ Set.empty
                        options =
                            defaultTxDiffOptions
                                { txDiffIncludeWitnesses = True
                                }
                        witnessPath = witnessKeyHashKey firstWitness
                    diffConwayTxWith options txA txB
                        `shouldBe` DiffNode
                            rootPath
                            ( DiffObject
                                (Map.singleton "body" Nothing)
                                ( Map.singleton
                                    "witnesses"
                                    ( DiffNode
                                        (DiffPath ["witnesses"])
                                        ( DiffObject
                                            ( witnessCommonExcept
                                                ["vkeys"]
                                                txA
                                            )
                                            ( Map.singleton
                                                "vkeys"
                                                ( DiffNode
                                                    ( DiffPath
                                                        [ "witnesses"
                                                        , "vkeys"
                                                        ]
                                                    )
                                                    ( DiffObject
                                                        Map.empty
                                                        Map.empty
                                                        ( Map.singleton
                                                            witnessPath
                                                            ( vkeyWitnessJson
                                                                firstWitness
                                                            )
                                                        )
                                                        Map.empty
                                                    )
                                                )
                                            )
                                            Map.empty
                                            Map.empty
                                        )
                                    )
                                )
                                Map.empty
                                Map.empty
                            )

        it "reports an opt-in Conway bootstrap witness insertion keyed by key hash" $ do
            tx <- loadFixture sampleHash
            case Set.toAscList (tx ^. witsTxL . addrTxWitsL) of
                [] ->
                    expectationFailure "fixture has no key witnesses"
                firstWitness : _ -> do
                    let bootstrapWitness =
                            bootstrapWitnessFromVKeyWitness firstWitness
                        txA =
                            tx
                                & witsTxL
                                    . bootAddrTxWitsL
                                    .~ Set.empty
                        txB =
                            tx
                                & witsTxL
                                    . bootAddrTxWitsL
                                    .~ Set.singleton bootstrapWitness
                        options =
                            defaultTxDiffOptions
                                { txDiffIncludeWitnesses = True
                                }
                        witnessPath =
                            bootstrapWitnessKeyHashKey bootstrapWitness
                    diffConwayTxWith options txA txB
                        `shouldBe` DiffNode
                            rootPath
                            ( DiffObject
                                (Map.singleton "body" Nothing)
                                ( Map.singleton
                                    "witnesses"
                                    ( DiffNode
                                        (DiffPath ["witnesses"])
                                        ( DiffObject
                                            ( witnessCommonExcept
                                                ["bootstraps"]
                                                txA
                                            )
                                            ( Map.singleton
                                                "bootstraps"
                                                ( DiffNode
                                                    ( DiffPath
                                                        [ "witnesses"
                                                        , "bootstraps"
                                                        ]
                                                    )
                                                    ( DiffObject
                                                        Map.empty
                                                        Map.empty
                                                        Map.empty
                                                        ( Map.singleton
                                                            witnessPath
                                                            ( bootstrapWitnessJson
                                                                bootstrapWitness
                                                            )
                                                        )
                                                    )
                                                )
                                            )
                                            Map.empty
                                            Map.empty
                                        )
                                    )
                                )
                                Map.empty
                                Map.empty
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
    hex <- loadFixtureHex hash
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

loadFixtureHex :: String -> IO Text
loadFixtureHex hash =
    Text.strip . Text.pack <$> readFile (fixturePath hash)

decodeFixtureHex :: Text -> IO ByteString
decodeFixtureHex hex =
    case Base16.decode (Text.encodeUtf8 hex) of
        Right raw ->
            pure raw
        Left err ->
            expectationFailure ("failed to decode fixture hex: " <> err)
                >> fail "fixture hex decode failed"

fixturePath :: String -> FilePath
fixturePath hash =
    "test/fixtures/mainnet-txbuild/" <> hash <> ".cbor.hex"

sampleHash :: String
sampleHash =
    "789f9a1393e3c9eacd19582ebb1b02b777696c8ddcedda2d8752cb5723c42ef6"

orderBlueprint :: Blueprint
orderBlueprint =
    Blueprint
        { blueprintPreamble =
            BlueprintPreamble
                { preambleTitle = "Swap orders"
                , preamblePlutusVersion = "v3"
                }
        , blueprintValidators =
            [ BlueprintValidator
                { validatorTitle = Just "swap"
                , validatorDatum =
                    Just
                        BlueprintArgument
                            { argumentTitle = Just "Order datum"
                            , argumentSchema = orderRedeemerSchema
                            }
                , validatorRedeemer =
                    Just
                        BlueprintArgument
                            { argumentTitle = Just "Order redeemer"
                            , argumentSchema = orderRedeemerSchema
                            }
                }
            ]
        , blueprintDefinitions = Map.empty
        }

orderRedeemerSchema :: BlueprintSchema
orderRedeemerSchema =
    BlueprintSchema
        { schemaTitle = Just "Order redeemer"
        , schemaKind =
            SchemaConstructor
                1
                [ BlueprintSchema
                    { schemaTitle = Just "amount"
                    , schemaKind = SchemaInteger
                    }
                , BlueprintSchema
                    { schemaTitle = Just "asset"
                    , schemaKind = SchemaBytes
                    }
                ]
        }

orderRedeemerData :: Integer -> Data ConwayEra
orderRedeemerData amount =
    Data
        ( PLC.Constr
            1
            [ PLC.I amount
            , PLC.B (BS8.pack "\xde\xad")
            ]
        )

coinJson :: Coin -> Aeson.Value
coinJson (Coin lovelace) =
    Aeson.object ["lovelace" .= lovelace]

strictMaybeCoinJson :: StrictMaybe Coin -> Aeson.Value
strictMaybeCoinJson SNothing =
    Aeson.Null
strictMaybeCoinJson (SJust coin) =
    coinJson coin

bodyCommonExcept ::
    [Text] ->
    ConwayTx ->
    Map.Map Text (Maybe Aeson.Value)
bodyCommonExcept omitted tx =
    Map.fromList
        [ (field, Just value)
        | (field, value) <- bodyFieldValues tx
        , field `notElem` omitted
        ]

witnessCommonExcept ::
    [Text] ->
    ConwayTx ->
    Map.Map Text (Maybe Aeson.Value)
witnessCommonExcept omitted tx =
    Map.fromList
        [ (field, Just value)
        | (field, value) <- witnessFieldValues tx
        , field `notElem` omitted
        ]

witnessFieldValues :: ConwayTx -> [(Text, Aeson.Value)]
witnessFieldValues tx =
    [
        ( "bootstraps"
        , bootstrapWitnessesJson $
            Set.toAscList (tx ^. witsTxL . bootAddrTxWitsL)
        )
    ,
        ( "datums"
        , datumWitnessesJson (tx ^. witsTxL . datsTxWitsL)
        )
    ,
        ( "redeemers"
        , redeemersJson (tx ^. witsTxL . rdmrsTxWitsL)
        )
    ,
        ( "scripts"
        , scriptsJson (tx ^. witsTxL . scriptTxWitsL)
        )
    ,
        ( "vkeys"
        , vkeyWitnessesJson $
            Set.toAscList (tx ^. witsTxL . addrTxWitsL)
        )
    ]

bodyFieldValues :: ConwayTx -> [(Text, Aeson.Value)]
bodyFieldValues tx =
    [
        ( "collateralInputs"
        , inputsJson $
            Set.toAscList (tx ^. bodyTxL . collateralInputsTxBodyL)
        )
    ,
        ( "fee"
        , coinJson (tx ^. bodyTxL . feeTxBodyL)
        )
    ,
        ( "inputs"
        , inputsJson $
            Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
        )
    ,
        ( "mint"
        , mintJson (tx ^. bodyTxL . mintTxBodyL)
        )
    ,
        ( "outputs"
        , outputsJson $
            toList (tx ^. bodyTxL . outputsTxBodyL)
        )
    ,
        ( "referenceInputs"
        , inputsJson $
            Set.toAscList (tx ^. bodyTxL . referenceInputsTxBodyL)
        )
    ,
        ( "requiredSigners"
        , keyHashesJson $
            Set.toAscList (tx ^. bodyTxL . reqSignerHashesTxBodyL)
        )
    ,
        ( "totalCollateral"
        , strictMaybeCoinJson (tx ^. bodyTxL . totalCollateralTxBodyL)
        )
    ,
        ( "validityInterval"
        , validityIntervalJson (tx ^. bodyTxL . vldtTxBodyL)
        )
    ,
        ( "withdrawals"
        , withdrawalsJson (tx ^. bodyTxL . withdrawalsTxBodyL)
        )
    ]

inputsJson :: [TxIn] -> Aeson.Value
inputsJson inputs =
    Aeson.toJSON (map txInJson inputs)

txInJson :: TxIn -> Aeson.Value
txInJson (TxIn (TxId safeHash) (TxIx index)) =
    Aeson.object
        [ "txId" .= hexText (hashToBytes (extractHash safeHash))
        , "index" .= index
        ]

mkTxIn :: Int -> TxIn
mkTxIn n =
    let hexStr =
            replicate 60 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in TxIn
            (TxId (unsafeMakeSafeHash h))
            (TxIx 0)

hexByte :: Int -> String
hexByte x =
    let s = "0123456789abcdef"
     in [s !! (x `div` 16), s !! (x `mod` 16)]

mkKeyHash :: Int -> KeyHash kr
mkKeyHash n =
    let hexStr =
            replicate 52 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in KeyHash h

mkWitnessKeyHash :: Int -> KeyHash Guard
mkWitnessKeyHash =
    mkKeyHash

mkRewardAccount :: Int -> AccountAddress
mkRewardAccount n =
    AccountAddress
        Testnet
        (AccountId (KeyHashObj (mkKeyHash n)))

mkPolicyId :: Int -> PolicyID
mkPolicyId n =
    let hexStr =
            replicate 52 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in PolicyID (ScriptHash h)

keyHashesJson :: [KeyHash Guard] -> Aeson.Value
keyHashesJson keyHashes =
    Aeson.toJSON (map keyHashJson keyHashes)

keyHashJson :: KeyHash Guard -> Aeson.Value
keyHashJson keyHash =
    Aeson.String (keyHashKey keyHash)

keyHashKey :: KeyHash kr -> Text
keyHashKey (KeyHash keyHash) =
    hexText (hashToBytes keyHash)

bootstrapWitnessesJson :: [BootstrapWitness] -> Aeson.Value
bootstrapWitnessesJson witnesses =
    Aeson.Object $
        KeyMap.fromList
            [ ( Key.fromText (bootstrapWitnessKeyHashKey witness)
              , bootstrapWitnessJson witness
              )
            | witness <- witnesses
            ]

bootstrapWitnessJson :: BootstrapWitness -> Aeson.Value
bootstrapWitnessJson witness =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) witness)
        ]

bootstrapWitnessKeyHashKey :: BootstrapWitness -> Text
bootstrapWitnessKeyHashKey witness =
    keyHashKey (hashKey (bwKey witness))

bootstrapWitnessFromVKeyWitness :: WitVKey Witness -> BootstrapWitness
bootstrapWitnessFromVKeyWitness (WitVKey key signature) =
    BootstrapWitness
        key
        signature
        (ChainCode (BS8.replicate 32 '\0'))
        BS8.empty

withdrawalsJson :: Withdrawals -> Aeson.Value
withdrawalsJson (Withdrawals withdrawals) =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (rewardAccountKey rewardAccount), coinJson coin)
            | (rewardAccount, coin) <- Map.toAscList withdrawals
            ]

rewardAccountKey :: AccountAddress -> Text
rewardAccountKey rewardAccount =
    hexText (serialize' (eraProtVerLow @ConwayEra) rewardAccount)

mintJson :: MultiAsset -> Aeson.Value
mintJson (MultiAsset policies) =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (policyIdKey policyId), assetQuantitiesJson assets)
            | (policyId, assets) <- Map.toAscList policies
            ]

assetQuantitiesJson :: Map.Map AssetName Integer -> Aeson.Value
assetQuantitiesJson assets =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (assetNameKey assetName), Aeson.toJSON quantity)
            | (assetName, quantity) <- Map.toAscList assets
            ]

policyIdKey :: PolicyID -> Text
policyIdKey (PolicyID scriptHash) =
    scriptHashKey scriptHash

scriptHashKey :: ScriptHash -> Text
scriptHashKey (ScriptHash scriptHash) =
    hexText (hashToBytes scriptHash)

dataHashKey :: DataHash -> Text
dataHashKey dataHash =
    hexText (hashToBytes (extractHash dataHash))

datumWitnessesJson :: TxDats ConwayEra -> Aeson.Value
datumWitnessesJson (TxDats datums) =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (dataHashKey dataHash), dataJson datum)
            | (dataHash, datum) <- Map.toAscList datums
            ]

redeemersJson :: Redeemers ConwayEra -> Aeson.Value
redeemersJson (Redeemers redeemers) =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (redeemerPurposeKey purpose), redeemerJson redeemer)
            | (purpose, redeemer) <- Map.toAscList redeemers
            ]

redeemerJson :: (Data ConwayEra, ExUnits) -> Aeson.Value
redeemerJson (redeemerData, exUnits) =
    Aeson.object
        [ "data" .= dataJson redeemerData
        , "exUnits" .= exUnitsJson exUnits
        ]

vkeyWitnessesJson :: [WitVKey Witness] -> Aeson.Value
vkeyWitnessesJson witnesses =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (witnessKeyHashKey witness), vkeyWitnessJson witness)
            | witness <- witnesses
            ]

vkeyWitnessJson :: WitVKey Witness -> Aeson.Value
vkeyWitnessJson witness =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) witness)
        ]

witnessKeyHashKey :: WitVKey Witness -> Text
witnessKeyHashKey witness =
    keyHashKey (witVKeyHash witness)

redeemerPurposeKey :: ConwayPlutusPurpose AsIx ConwayEra -> Text
redeemerPurposeKey (ConwaySpending (AsIx index)) =
    indexedRedeemerPurposeKey "spending" index
redeemerPurposeKey (ConwayMinting (AsIx index)) =
    indexedRedeemerPurposeKey "minting" index
redeemerPurposeKey (ConwayCertifying (AsIx index)) =
    indexedRedeemerPurposeKey "certifying" index
redeemerPurposeKey (ConwayRewarding (AsIx index)) =
    indexedRedeemerPurposeKey "rewarding" index
redeemerPurposeKey (ConwayVoting (AsIx index)) =
    indexedRedeemerPurposeKey "voting" index
redeemerPurposeKey (ConwayProposing (AsIx index)) =
    indexedRedeemerPurposeKey "proposing" index

indexedRedeemerPurposeKey :: (Show index) => Text -> index -> Text
indexedRedeemerPurposeKey label index =
    label <> "." <> Text.pack (show index)

assetNameKey :: AssetName -> Text
assetNameKey (AssetName bytes) =
    hexText (SBS.fromShort bytes)

scriptsJson :: Map.Map ScriptHash (Script ConwayEra) -> Aeson.Value
scriptsJson scripts =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText (scriptHashKey scriptHash), scriptJson script)
            | (scriptHash, script) <- Map.toAscList scripts
            ]

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

dataJson :: Data ConwayEra -> Aeson.Value
dataJson dataValue =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) dataValue)
        ]

exUnitsJson :: ExUnits -> Aeson.Value
exUnitsJson (ExUnits memory steps) =
    Aeson.object
        [ "memory" .= memory
        , "steps" .= steps
        ]

integerData :: Integer -> Data ConwayEra
integerData value =
    Data (PLC.I value)

inlineIntegerDatum :: Integer -> Datum ConwayEra
inlineIntegerDatum value =
    Datum $
        dataToBinaryData (integerData value)

inlineOrderDatum :: Integer -> Datum ConwayEra
inlineOrderDatum amount =
    Datum $
        dataToBinaryData (orderRedeemerData amount)

referenceScriptJson :: StrictMaybe (Script ConwayEra) -> Aeson.Value
referenceScriptJson SNothing =
    Aeson.Null
referenceScriptJson (SJust script) =
    Aeson.object
        [ "cbor"
            .= hexText (serialize' (eraProtVerLow @ConwayEra) script)
        ]

scriptJson :: Script ConwayEra -> Aeson.Value
scriptJson script =
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
