{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.TxDiff.ConwaySpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Text (Text)
import Data.Text qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    outputsTxBodyL,
    vldtTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    diffConwayTx,
 )
import Cardano.Slotting.Slot (SlotNo (..))

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
                                                    Map.empty
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
    Aeson.object ["coin" .= coinJson (output ^. coinTxOutL)]

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
