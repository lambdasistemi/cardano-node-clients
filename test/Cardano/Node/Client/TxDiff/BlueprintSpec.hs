{-# LANGUAGE OverloadedStrings #-}

module Cardano.Node.Client.TxDiff.BlueprintSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Map.Strict qualified as Map
import Test.Hspec

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    OpenValue (..),
    TxDiffDataKind (..),
    TxDiffDataSelector (..),
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint (..),
    BlueprintArgument (..),
    BlueprintArgumentKind (..),
    BlueprintArgumentSelector (..),
    BlueprintDiff (..),
    BlueprintFallbackReason (..),
    BlueprintMatchError (..),
    BlueprintPreamble (..),
    BlueprintSchema (..),
    BlueprintSchemaKind (..),
    BlueprintValidator (..),
    blueprintDataDecoder,
    decodeBlueprintData,
    diffBlueprintArgumentData,
    diffBlueprintData,
    matchBlueprintArgument,
    parseBlueprintJSON,
 )
import PlutusCore.Data qualified as PLC

spec :: Spec
spec =
    describe "Plutus blueprints" $ do
        it "parses validators, datum and redeemer schemas, and definitions" $ do
            parseBlueprintJSON blueprintJson
                `shouldBe` Right
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
                                            , argumentSchema =
                                                BlueprintSchema
                                                    { schemaTitle = Nothing
                                                    , schemaKind =
                                                        SchemaReference
                                                            "OrderDatum"
                                                    }
                                            }
                                , validatorRedeemer =
                                    Just
                                        BlueprintArgument
                                            { argumentTitle =
                                                Just "Order redeemer"
                                            , argumentSchema =
                                                BlueprintSchema
                                                    { schemaTitle = Nothing
                                                    , schemaKind =
                                                        SchemaConstructor
                                                            1
                                                            [ BlueprintSchema
                                                                { schemaTitle =
                                                                    Just "amount"
                                                                , schemaKind =
                                                                    SchemaInteger
                                                                }
                                                            , BlueprintSchema
                                                                { schemaTitle =
                                                                    Just "asset"
                                                                , schemaKind =
                                                                    SchemaBytes
                                                                }
                                                            ]
                                                    }
                                            }
                                }
                            ]
                        , blueprintDefinitions =
                            Map.singleton
                                "OrderDatum"
                                BlueprintSchema
                                    { schemaTitle = Just "Order datum"
                                    , schemaKind =
                                        SchemaConstructor
                                            0
                                            [ BlueprintSchema
                                                { schemaTitle = Just "owner"
                                                , schemaKind = SchemaBytes
                                                }
                                            ]
                                    }
                        }

        it "matches a validator datum schema and resolves local definitions" $
            case parseBlueprintJSON blueprintJson of
                Left err ->
                    expectationFailure err
                Right blueprint ->
                    matchBlueprintArgument
                        [blueprint]
                        BlueprintArgumentSelector
                            { selectorValidatorTitle = Just "swap"
                            , selectorArgumentKind = BlueprintDatum
                            }
                        `shouldBe` Right
                            BlueprintSchema
                                { schemaTitle = Just "Order datum"
                                , schemaKind =
                                    SchemaConstructor
                                        0
                                        [ BlueprintSchema
                                            { schemaTitle = Just "owner"
                                            , schemaKind = SchemaBytes
                                            }
                                        ]
                                }

        it "parses Aiken blueprints with generic data and list definitions" $
            case parseBlueprintJSON aikenSubsetBlueprintJson of
                Left err ->
                    expectationFailure err
                Right blueprint -> do
                    Map.lookup "Data" (blueprintDefinitions blueprint)
                        `shouldBe` Just
                            ( BlueprintSchema
                                { schemaTitle = Just "Data"
                                , schemaKind = SchemaData
                                }
                            )
                    Map.lookup "List$Int" (blueprintDefinitions blueprint)
                        `shouldBe` Just
                            ( BlueprintSchema
                                { schemaTitle = Nothing
                                , schemaKind =
                                    SchemaListOf
                                        BlueprintSchema
                                            { schemaTitle = Nothing
                                            , schemaKind = SchemaReference "Int"
                                            }
                                }
                            )

        it "selects the only matching blueprint argument that decodes the datum" $ do
            let wrongDatum =
                    BlueprintArgument
                        { argumentTitle = Just "Wrong datum"
                        , argumentSchema =
                            BlueprintSchema
                                { schemaTitle = Just "Wrong datum"
                                , schemaKind = SchemaConstructor 99 []
                                }
                        }
                rightValidator =
                    BlueprintValidator
                        { validatorTitle = Just "right"
                        , validatorDatum =
                            Just
                                BlueprintArgument
                                    { argumentTitle = Just "Order datum"
                                    , argumentSchema = orderSchema
                                    }
                        , validatorRedeemer = Nothing
                        }
                wrongValidator =
                    rightValidator
                        { validatorTitle = Just "wrong"
                        , validatorDatum = Just wrongDatum
                        }
                blueprint =
                    Blueprint
                        { blueprintPreamble =
                            BlueprintPreamble
                                { preambleTitle = "ambiguous"
                                , preamblePlutusVersion = "v3"
                                }
                        , blueprintValidators = [wrongValidator, rightValidator]
                        , blueprintDefinitions = Map.empty
                        }
            blueprintDataDecoder
                [blueprint]
                TxDiffDataSelector
                    { txDiffDataValidatorTitle = Nothing
                    , txDiffDataKind = TxDiffDatum
                    }
                (orderDatum 42)
                `shouldBe` Right
                    ( OpenObject
                        ( Map.fromList
                            [ ("amount", OpenInteger 42)
                            , ("owner", OpenBytes "dead")
                            ]
                        )
                    )

        it "converts constructor data into an open application value" $ do
            decodeBlueprintData orderSchema (orderDatum 42)
                `shouldBe` Right
                    ( OpenObject
                        ( Map.fromList
                            [ ("amount", OpenInteger 42)
                            , ("owner", OpenBytes "dead")
                            ]
                        )
                    )

        it "diffs decoded constructor fields as open application values" $ do
            diffBlueprintData orderSchema (orderDatum 42) (orderDatum 43)
                `shouldBe` Right
                    ( DiffNode
                        rootPath
                        ( DiffObject
                            ( Map.fromList
                                [ ("owner", Just (Aeson.object ["bytes" .= ("dead" :: String)]))
                                ]
                            )
                            ( Map.fromList
                                [
                                    ( "amount"
                                    , DiffNode
                                        (DiffPath ["amount"])
                                        ( DiffChanged
                                            (Aeson.Number 42)
                                            (Aeson.Number 43)
                                        )
                                    )
                                ]
                            )
                            Map.empty
                            Map.empty
                        )
                    )

        it "falls back to raw data when no blueprint argument matches" $
            case diffBlueprintArgumentData
                []
                orderDatumSelector
                (orderDatum 42)
                (orderDatum 43) of
                BlueprintDiffFallback
                    (BlueprintMatchFallback BlueprintArgumentMissing)
                    diff ->
                        diff `shouldBeRawDataChange` rootPath
                other ->
                    expectationFailure ("unexpected fallback result: " <> show other)

        it "falls back to raw data when blueprint argument matches ambiguously" $
            case parseBlueprintJSON blueprintJson of
                Left err ->
                    expectationFailure err
                Right blueprint ->
                    case diffBlueprintArgumentData
                        [blueprint, blueprint]
                        orderDatumSelector
                        (orderDatum 42)
                        (orderDatum 43) of
                        BlueprintDiffFallback
                            ( BlueprintMatchFallback
                                    (BlueprintArgumentAmbiguous ["swap", "swap"])
                                )
                            diff ->
                                diff `shouldBeRawDataChange` rootPath
                        other ->
                            expectationFailure $
                                "unexpected fallback result: " <> show other

rootPath :: DiffPath
rootPath =
    DiffPath []

orderSchema :: BlueprintSchema
orderSchema =
    BlueprintSchema
        { schemaTitle = Just "Order"
        , schemaKind =
            SchemaConstructor
                0
                [ BlueprintSchema
                    { schemaTitle = Just "owner"
                    , schemaKind = SchemaBytes
                    }
                , BlueprintSchema
                    { schemaTitle = Just "amount"
                    , schemaKind = SchemaInteger
                    }
                ]
        }

orderDatum :: Integer -> Data ConwayEra
orderDatum amount =
    Data
        ( PLC.Constr
            0
            [ PLC.B (BS.pack [0xde, 0xad])
            , PLC.I amount
            ]
        )

orderDatumSelector :: BlueprintArgumentSelector
orderDatumSelector =
    BlueprintArgumentSelector
        { selectorValidatorTitle = Just "swap"
        , selectorArgumentKind = BlueprintDatum
        }

shouldBeRawDataChange :: DiffNode -> DiffPath -> Expectation
shouldBeRawDataChange (DiffNode path (DiffChanged left right)) expectedPath = do
    path `shouldBe` expectedPath
    left `shouldSatisfy` hasCborField
    right `shouldSatisfy` hasCborField
    left `shouldNotBe` right
shouldBeRawDataChange other _ =
    expectationFailure ("expected raw data change, got: " <> show other)

hasCborField :: Aeson.Value -> Bool
hasCborField (Aeson.Object value) =
    KeyMap.member "cbor" value
hasCborField _ =
    False

blueprintJson :: LBS8.ByteString
blueprintJson =
    "{\
    \  \"preamble\": {\
    \    \"title\": \"Swap orders\",\
    \    \"plutusVersion\": \"v3\"\
    \  },\
    \  \"validators\": [\
    \    {\
    \      \"title\": \"swap\",\
    \      \"datum\": {\
    \        \"title\": \"Order datum\",\
    \        \"schema\": {\"$ref\": \"#/definitions/OrderDatum\"}\
    \      },\
    \      \"redeemer\": {\
    \        \"title\": \"Order redeemer\",\
    \        \"schema\": {\
    \          \"dataType\": \"constructor\",\
    \          \"index\": 1,\
    \          \"fields\": [\
    \            {\"title\": \"amount\", \"dataType\": \"integer\"},\
    \            {\"title\": \"asset\", \"dataType\": \"bytes\"}\
    \          ]\
    \        }\
    \      }\
    \    }\
    \  ],\
    \  \"definitions\": {\
    \    \"OrderDatum\": {\
    \      \"title\": \"Order datum\",\
    \      \"dataType\": \"constructor\",\
    \      \"index\": 0,\
    \      \"fields\": [\
    \        {\"title\": \"owner\", \"dataType\": \"bytes\"}\
    \      ]\
    \    }\
    \  }\
    \}"

aikenSubsetBlueprintJson :: LBS8.ByteString
aikenSubsetBlueprintJson =
    "{\
    \  \"preamble\": {\
    \    \"title\": \"Aiken subset\",\
    \    \"plutusVersion\": \"v3\"\
    \  },\
    \  \"validators\": [],\
    \  \"definitions\": {\
    \    \"Bool\": {\
    \      \"title\": \"Bool\",\
    \      \"anyOf\": [\
    \        {\"title\": \"False\", \"dataType\": \"constructor\", \"index\": 0},\
    \        {\"title\": \"True\", \"dataType\": \"constructor\", \"index\": 1}\
    \      ]\
    \    },\
    \    \"Data\": {\
    \      \"title\": \"Data\",\
    \      \"description\": \"Any Plutus data.\"\
    \    },\
    \    \"Int\": {\"dataType\": \"integer\"},\
    \    \"List$Int\": {\
    \      \"dataType\": \"list\",\
    \      \"items\": {\"$ref\": \"#/definitions/Int\"}\
    \    }\
    \  }\
    \}"
