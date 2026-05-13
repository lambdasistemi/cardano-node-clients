{-# LANGUAGE OverloadedStrings #-}

module Cardano.Node.Client.TxDiff.BlueprintSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
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
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint (..),
    BlueprintArgument (..),
    BlueprintArgumentKind (..),
    BlueprintArgumentSelector (..),
    BlueprintPreamble (..),
    BlueprintSchema (..),
    BlueprintSchemaKind (..),
    BlueprintValidator (..),
    decodeBlueprintData,
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
