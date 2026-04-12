{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.TxBuildGoldenSpec (spec) where

import Control.Monad (void)
import Data.Foldable (for_, toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (
    RewardAccount,
    Withdrawals (..),
 )
import Cardano.Ledger.Allegra.Scripts (
    ValidityInterval (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Scripts.Data (Data)
import Cardano.Ledger.Api.Tx (
    Tx,
    auxDataTxL,
    bodyTxL,
    getPlutusData,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (metadataTxAuxDataL)
import Cardano.Ledger.Mary.Value (
    MultiAsset (..),
 )
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Node.Client.TxBuild (
    TxBuild,
    attachScript,
    collateral,
    draft,
    mint,
    output,
    reference,
    requireSignature,
    setMetadata,
    spend,
    spendScript,
    validFrom,
    validTo,
    withdraw,
    withdrawScript,
 )
import Cardano.Slotting.Slot (SlotNo)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

spec :: Spec
spec =
    describe "TxBuild mainnet golden vectors" $
        for_ goldenCases $ \golden ->
            it (goldenName golden) $ do
                case goldenPendingReason golden of
                    Just reason ->
                        pendingWith reason
                    Nothing -> do
                        expected <- loadGoldenTx golden
                        let actual =
                                draft emptyPParams (txBuildFromTx expected)
                        assertStructurallyEquivalent expected actual

data GoldenCase = GoldenCase
    { goldenName :: String
    , goldenHash :: String
    , goldenPendingReason :: Maybe String
    }

goldenCases :: [GoldenCase]
goldenCases =
    [ GoldenCase "Minswap V2 batch" "602a2baba60d7d753dfe513d901bb11fc65c30f1bf99c82a6e188721c4225108" Nothing
    , GoldenCase "Minswap V2 order" "789f9a1393e3c9eacd19582ebb1b02b777696c8ddcedda2d8752cb5723c42ef6" Nothing
    , GoldenCase "SundaeSwap V3" "3dc7947885b66b94b862c5eaa3fb3078b164217bfb58962839affc3c3ef6ab0b" Nothing
    , GoldenCase "SundaeSwap scoop" "5029390a4e5ebc024f6a68628bf1bf8d95e278deeedec620c1dabfbadf85e2f5" Nothing
    , GoldenCase "Lenfi borrow" "4d219f276f79c39535047649ed2bfe8bb87f749150938c0fdfe654c786033854" Nothing
    , GoldenCase "Liqwid supply" "bdbfa3f2d1ec9c3fb0351fa6da6672f410ed50fd4f88f0b0348e4eb2b39a8ef2" Nothing
    , GoldenCase "JPG Store NFT" "919e1b199547f9fb00402ae46c007ea42c1fc382fb090af90357f766e287fa6b" Nothing
    , GoldenCase "STEAK mine" "0fe086ab41e4b14a070d491a08bcddcc011afa1e48d6c0c6430bf82d7968028e" Nothing
    , GoldenCase
        "Indigo stability"
        "17a8e6072000081991c1aa1fd69be9cca44acf0ab2fae984de7cc020f3fc7fe5"
        (Just "Blockfrost's CBOR fixture is rejected by cardano-ledger decoders v9-v11 with `Empty list found, expected non-empty`; this vector needs a decoder-compatible replacement or a different decode path.")
    , GoldenCase "WingRiders swap" "23f8ade58f538e09d9741cd6d7d88fd394ef29fd17880f0539b685018d3d5f29" Nothing
    , GoldenCase "Indigo iUSD" "b4b28b84f67a21a627d9ad3a64a56aa13e8e31250715d0aa3563a84d94ab4a36" Nothing
    , GoldenCase "Recent batch" "b28a2813677f60223ef195b2d7f3344b2f98f627b7e0e7957d484fdeb3fed409" Nothing
    ]

loadGoldenTx :: GoldenCase -> IO (Tx ConwayEra)
loadGoldenTx golden = do
    hex <-
        fmap (T.strip . T.pack) $
            readFile (fixturePath (goldenHash golden))
    case
        decodeFullAnnotatorFromHexText
            (natVersion @11)
            "mainnet golden tx"
            (decCBOR :: forall s. Decoder s (Annotator (Tx ConwayEra)))
            hex
        of
        Left err ->
            expectationFailure
                ("failed to decode fixture " <> goldenHash golden <> ": " <> show err)
                >> fail "fixture decode failed"
        Right tx ->
            pure tx

fixturePath :: String -> FilePath
fixturePath hash =
    "test/fixtures/mainnet-txbuild/" <> hash <> ".cbor.hex"

txBuildFromTx :: Tx ConwayEra -> TxBuild q e ()
txBuildFromTx tx = do
    mapM_ addSpend indexedInputs
    mapM_ collateral (Set.toAscList collateralInputs)
    mapM_ reference (Set.toAscList referenceInputs)
    mapM_ (void . output) outputs
    mapM_ attachScript witnessScripts
    mapM_ addMint indexedMints
    mapM_ addWithdrawal (Map.toAscList withdrawalMap)
    for_ (invalidBeforeSlot tx) validFrom
    for_ (invalidHereafterSlot tx) validTo
    mapM_ requireSignature (Set.toAscList requiredSigners)
    mapM_ (uncurry setMetadata) (Map.toAscList metadataMap)
  where
    body = tx ^. bodyTxL
    indexedInputs = zip [0 :: Word32 ..] (Set.toAscList (body ^. inputsTxBodyL))
    collateralInputs = body ^. collateralInputsTxBodyL
    referenceInputs = body ^. referenceInputsTxBodyL
    outputs = toList (body ^. outputsTxBodyL)
    witnessScripts = tx ^. witsTxL . scriptTxWitsL
    MultiAsset mintPolicies = body ^. mintTxBodyL
    indexedMints = zip [0 :: Word32 ..] (Map.toAscList mintPolicies)
    Withdrawals withdrawalMap = body ^. withdrawalsTxBodyL
    requiredSigners = body ^. reqSignerHashesTxBodyL
    metadataMap = txMetadata tx
    spendRedeemers = indexedSpendingRedeemers tx
    mintRedeemers = indexedMintRedeemers tx
    withdrawalRedeemers = indexedWithdrawalRedeemers tx

    addSpend (ix, txIn) =
        case Map.lookup ix spendRedeemers of
            Nothing -> void (spend txIn)
            Just redeemer ->
                void (spendScript txIn (RawPlutusData (getPlutusData redeemer)))

    addMint (ix, (policyId, assets)) =
        case Map.lookup ix mintRedeemers of
            Nothing ->
                error ("fixture mint missing redeemer for policy index " <> show ix)
            Just redeemer ->
                mint
                    policyId
                    assets
                    (RawPlutusData (getPlutusData redeemer))

    addWithdrawal (rewardAccount, amount) =
        case Map.lookup rewardAccount withdrawalRedeemers of
            Nothing ->
                withdraw rewardAccount amount
            Just redeemer ->
                withdrawScript
                    rewardAccount
                    amount
                    (RawPlutusData (getPlutusData redeemer))

assertStructurallyEquivalent :: Tx ConwayEra -> Tx ConwayEra -> Expectation
assertStructurallyEquivalent expected actual = do
    actual ^. bodyTxL . inputsTxBodyL
        `shouldBe` (expected ^. bodyTxL . inputsTxBodyL)
    actual ^. bodyTxL . collateralInputsTxBodyL
        `shouldBe` (expected ^. bodyTxL . collateralInputsTxBodyL)
    actual ^. bodyTxL . referenceInputsTxBodyL
        `shouldBe` (expected ^. bodyTxL . referenceInputsTxBodyL)
    actual ^. bodyTxL . outputsTxBodyL
        `shouldBe` (expected ^. bodyTxL . outputsTxBodyL)
    actual ^. bodyTxL . mintTxBodyL
        `shouldBe` (expected ^. bodyTxL . mintTxBodyL)
    actual ^. bodyTxL . withdrawalsTxBodyL
        `shouldBe` (expected ^. bodyTxL . withdrawalsTxBodyL)
    actual ^. bodyTxL . reqSignerHashesTxBodyL
        `shouldBe` (expected ^. bodyTxL . reqSignerHashesTxBodyL)
    actual ^. bodyTxL . vldtTxBodyL
        `shouldBe` (expected ^. bodyTxL . vldtTxBodyL)
    txMetadata actual `shouldBe` txMetadata expected
    actual ^. witsTxL . scriptTxWitsL
        `shouldBe` (expected ^. witsTxL . scriptTxWitsL)
    normalizedRedeemers actual `shouldBe` normalizedRedeemers expected

txMetadata :: Tx ConwayEra -> Map.Map Word64 Metadatum
txMetadata tx =
    case tx ^. auxDataTxL of
        SJust aux -> aux ^. metadataTxAuxDataL
        SNothing -> Map.empty

normalizedRedeemers ::
    Tx ConwayEra ->
    Map.Map (ConwayPlutusPurpose AsIx ConwayEra) PLC.Data
normalizedRedeemers tx =
    Map.map (getPlutusData . fst) redeemers
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL

indexedSpendingRedeemers :: Tx ConwayEra -> Map.Map Word32 (Data ConwayEra)
indexedSpendingRedeemers tx =
    Map.fromList
        [ (ix, redeemer)
        | (ConwaySpending (AsIx ix), (redeemer, _)) <- Map.toList redeemers
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL

indexedMintRedeemers :: Tx ConwayEra -> Map.Map Word32 (Data ConwayEra)
indexedMintRedeemers tx =
    Map.fromList
        [ (ix, redeemer)
        | (ConwayMinting (AsIx ix), (redeemer, _)) <- Map.toList redeemers
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL

indexedWithdrawalRedeemers ::
    Tx ConwayEra ->
    Map.Map RewardAccount (Data ConwayEra)
indexedWithdrawalRedeemers tx =
    Map.fromList
        [ (rewardAccount, redeemer)
        | (rewardAccount, ix) <- withdrawalIndices
        , Just redeemer <- [Map.lookup ix rewardRedeemers]
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    rewardRedeemers =
        Map.fromList
            [ (ix, redeemer)
            | (ConwayRewarding (AsIx ix), (redeemer, _)) <- Map.toList redeemers
            ]
    Withdrawals withdrawals = tx ^. bodyTxL . withdrawalsTxBodyL
    withdrawalIndices = zip (Map.keys withdrawals) [0 :: Word32 ..]

invalidBeforeSlot :: Tx ConwayEra -> Maybe SlotNo
invalidBeforeSlot tx =
    case invalidBefore (tx ^. bodyTxL . vldtTxBodyL) of
        SJust slot -> Just slot
        SNothing -> Nothing

invalidHereafterSlot :: Tx ConwayEra -> Maybe SlotNo
invalidHereafterSlot tx =
    case invalidHereafter (tx ^. bodyTxL . vldtTxBodyL) of
        SJust slot -> Just slot
        SNothing -> Nothing

newtype RawPlutusData = RawPlutusData PLC.Data

instance ToData RawPlutusData where
    toBuiltinData (RawPlutusData datum) =
        BuiltinData datum
