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
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Alonzo.TxWits (TxDats (..))
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    dataToBinaryData,
    hashData,
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
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
import Cardano.Ledger.Api.Tx.Wits (datsTxWitsL, scriptTxWitsL)
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
    KeyRole (Guard),
 )
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MultiAsset (..),
    PolicyID (..),
 )
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
    defaultTxDiffOptions,
    diffConwayTx,
    diffConwayTxWith,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import PlutusCore.Data qualified as PLC

spec :: Spec
spec =
    describe "Conway transactions" $ do
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
                                    ( Map.singleton
                                        "datums"
                                        (Just (Aeson.object []))
                                    )
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
                                    ( Map.singleton
                                        "scripts"
                                        (Just (Aeson.object []))
                                    )
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
                                                    (dataJson datumData)
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
keyHashJson (KeyHash keyHash) =
    Aeson.String (hexText (hashToBytes keyHash))

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

assetNameKey :: AssetName -> Text
assetNameKey (AssetName bytes) =
    hexText (SBS.fromShort bytes)

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

integerData :: Integer -> Data ConwayEra
integerData value =
    Data (PLC.I value)

inlineIntegerDatum :: Integer -> Datum ConwayEra
inlineIntegerDatum value =
    Datum $
        dataToBinaryData (integerData value)

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
