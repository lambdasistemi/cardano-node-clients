{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.TxDiff.ConwaySpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, vldtTxBodyL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
 )
import Cardano.Ledger.Coin (Coin (..))
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
            let tx' = tx & bodyTxL . feeTxBodyL .~ Coin 42
            diffConwayTx tx tx'
                `shouldBe` bodyDiff
                    ( Map.fromList
                        [
                            ( "validityInterval"
                            , Just (validityIntervalJson validity)
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
