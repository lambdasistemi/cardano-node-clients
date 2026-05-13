{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.TxDiff.Blueprint
Description : Plutus blueprint parsing for transaction diffs.

This module parses the CIP-0057 subset needed by the TxDiff blueprint
boundary: validators, datum and redeemer argument schemas, definitions, and
the Plutus data schema forms needed to name constructor fields.
-}
module Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint (..),
    BlueprintArgument (..),
    BlueprintArgumentKind (..),
    BlueprintArgumentSelector (..),
    BlueprintDataError (..),
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
) where

import Data.Aeson (
    FromJSON (..),
    Object,
    eitherDecode,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, (.!=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    OpenValue (..),
    TxDiffDataKind (..),
    TxDiffDataSelector (..),
    diffOpenValue,
 )
import PlutusCore.Data qualified as PLC

data Blueprint = Blueprint
    { blueprintPreamble :: BlueprintPreamble
    , blueprintValidators :: [BlueprintValidator]
    , blueprintDefinitions :: Map Text BlueprintSchema
    }
    deriving stock (Eq, Show)

data BlueprintPreamble = BlueprintPreamble
    { preambleTitle :: Text
    , preamblePlutusVersion :: Text
    }
    deriving stock (Eq, Show)

data BlueprintValidator = BlueprintValidator
    { validatorTitle :: Maybe Text
    , validatorDatum :: Maybe BlueprintArgument
    , validatorRedeemer :: Maybe BlueprintArgument
    }
    deriving stock (Eq, Show)

data BlueprintArgument = BlueprintArgument
    { argumentTitle :: Maybe Text
    , argumentSchema :: BlueprintSchema
    }
    deriving stock (Eq, Show)

data BlueprintArgumentKind
    = BlueprintDatum
    | BlueprintRedeemer
    deriving stock (Eq, Show)

data BlueprintArgumentSelector = BlueprintArgumentSelector
    { selectorValidatorTitle :: Maybe Text
    , selectorArgumentKind :: BlueprintArgumentKind
    }
    deriving stock (Eq, Show)

data BlueprintMatchError
    = BlueprintArgumentMissing
    | BlueprintArgumentAmbiguous [Text]
    | BlueprintDefinitionMissing Text
    | BlueprintDefinitionCycle Text
    deriving stock (Eq, Show)

data BlueprintDiff
    = BlueprintDiffDecoded DiffNode
    | BlueprintDiffFallback BlueprintFallbackReason DiffNode
    deriving stock (Eq, Show)

data BlueprintFallbackReason
    = BlueprintMatchFallback BlueprintMatchError
    | BlueprintDataFallback BlueprintDataError
    deriving stock (Eq, Show)

data BlueprintDataError
    = BlueprintDataTypeMismatch Text
    | BlueprintConstructorMismatch
        { expectedConstructorIndex :: Integer
        , actualConstructorIndex :: Integer
        }
    | BlueprintFieldCountMismatch
        { expectedFieldCount :: Int
        , actualFieldCount :: Int
        }
    | BlueprintUnresolvedReference Text
    deriving stock (Eq, Show)

data BlueprintSchema = BlueprintSchema
    { schemaTitle :: Maybe Text
    , schemaKind :: BlueprintSchemaKind
    }
    deriving stock (Eq, Show)

data BlueprintSchemaKind
    = SchemaInteger
    | SchemaBytes
    | SchemaConstructor Integer [BlueprintSchema]
    | SchemaReference Text
    deriving stock (Eq, Show)

parseBlueprintJSON :: LBS.ByteString -> Either String Blueprint
parseBlueprintJSON =
    eitherDecode

blueprintDataDecoder ::
    [Blueprint] -> TxDiffDataSelector -> Data ConwayEra -> Either Text OpenValue
blueprintDataDecoder blueprints selector datum = do
    schema <-
        case matchBlueprintArgument blueprints (blueprintArgumentSelector selector) of
            Left err ->
                Left (Text.pack (show (BlueprintMatchFallback err)))
            Right matchedSchema ->
                Right matchedSchema
    case decodeBlueprintData schema datum of
        Left err ->
            Left (Text.pack (show (BlueprintDataFallback err)))
        Right value ->
            Right value

blueprintArgumentSelector :: TxDiffDataSelector -> BlueprintArgumentSelector
blueprintArgumentSelector selector =
    BlueprintArgumentSelector
        { selectorValidatorTitle = txDiffDataValidatorTitle selector
        , selectorArgumentKind =
            txDiffBlueprintArgumentKind (txDiffDataKind selector)
        }

txDiffBlueprintArgumentKind :: TxDiffDataKind -> BlueprintArgumentKind
txDiffBlueprintArgumentKind TxDiffDatum =
    BlueprintDatum
txDiffBlueprintArgumentKind TxDiffRedeemer =
    BlueprintRedeemer

decodeBlueprintData ::
    BlueprintSchema -> Data ConwayEra -> Either BlueprintDataError OpenValue
decodeBlueprintData schema (Data value) =
    decodeBlueprintValue schema value

diffBlueprintData ::
    BlueprintSchema ->
    Data ConwayEra ->
    Data ConwayEra ->
    Either BlueprintDataError DiffNode
diffBlueprintData schema left right = do
    leftOpen <- decodeBlueprintData schema left
    rightOpen <- decodeBlueprintData schema right
    pure (diffOpenValue leftOpen rightOpen)

diffBlueprintArgumentData ::
    [Blueprint] ->
    BlueprintArgumentSelector ->
    Data ConwayEra ->
    Data ConwayEra ->
    BlueprintDiff
diffBlueprintArgumentData blueprints selector left right =
    case matchBlueprintArgument blueprints selector of
        Left err ->
            BlueprintDiffFallback
                (BlueprintMatchFallback err)
                (rawBlueprintDataDiff left right)
        Right schema ->
            case diffBlueprintData schema left right of
                Left err ->
                    BlueprintDiffFallback
                        (BlueprintDataFallback err)
                        (rawBlueprintDataDiff left right)
                Right diff ->
                    BlueprintDiffDecoded diff

rawBlueprintDataDiff :: Data ConwayEra -> Data ConwayEra -> DiffNode
rawBlueprintDataDiff left right
    | left == right =
        DiffNode
            (DiffPath [])
            (DiffSame (Just (rawBlueprintDataValue left)))
    | otherwise =
        DiffNode
            (DiffPath [])
            ( DiffChanged
                (rawBlueprintDataValue left)
                (rawBlueprintDataValue right)
            )

rawBlueprintDataValue :: Data ConwayEra -> Aeson.Value
rawBlueprintDataValue datum =
    Aeson.object
        [ "cbor" .= hexText (serialize' (eraProtVerLow @ConwayEra) datum)
        ]

decodeBlueprintValue ::
    BlueprintSchema -> PLC.Data -> Either BlueprintDataError OpenValue
decodeBlueprintValue schema value =
    case schemaKind schema of
        SchemaInteger ->
            case value of
                PLC.I integer ->
                    Right (OpenInteger integer)
                _ ->
                    Left (BlueprintDataTypeMismatch "integer")
        SchemaBytes ->
            case value of
                PLC.B bytes ->
                    Right (OpenBytes (hexText bytes))
                _ ->
                    Left (BlueprintDataTypeMismatch "bytes")
        SchemaConstructor expectedIndex fields ->
            case value of
                PLC.Constr actualIndex values
                    | actualIndex /= expectedIndex ->
                        Left
                            BlueprintConstructorMismatch
                                { expectedConstructorIndex = expectedIndex
                                , actualConstructorIndex = actualIndex
                                }
                    | length fields /= length values ->
                        Left
                            BlueprintFieldCountMismatch
                                { expectedFieldCount = length fields
                                , actualFieldCount = length values
                                }
                    | otherwise ->
                        OpenObject . Map.fromList
                            <$> traverse
                                decodeField
                                (zip [0 :: Int ..] (zip fields values))
                _ ->
                    Left (BlueprintDataTypeMismatch "constructor")
        SchemaReference reference ->
            Left (BlueprintUnresolvedReference reference)
  where
    decodeField (index, (fieldSchema, fieldValue)) = do
        decodedValue <- decodeBlueprintValue fieldSchema fieldValue
        pure (fieldName index fieldSchema, decodedValue)

fieldName :: Int -> BlueprintSchema -> Text
fieldName index schema =
    case schemaTitle schema of
        Just title ->
            title
        Nothing ->
            "field" <> Text.pack (show index)

hexText :: BS.ByteString -> Text
hexText =
    TextEncoding.decodeUtf8 . Base16.encode

matchBlueprintArgument ::
    [Blueprint] ->
    BlueprintArgumentSelector ->
    Either BlueprintMatchError BlueprintSchema
matchBlueprintArgument blueprints selector =
    case matchingArguments blueprints selector of
        [] ->
            Left BlueprintArgumentMissing
        [(blueprint, _, argument)] ->
            resolveBlueprintSchema blueprint (argumentSchema argument)
        matches ->
            Left $
                BlueprintArgumentAmbiguous
                    [ matchLabel blueprint validator
                    | (blueprint, validator, _) <- matches
                    ]

matchingArguments ::
    [Blueprint] ->
    BlueprintArgumentSelector ->
    [(Blueprint, BlueprintValidator, BlueprintArgument)]
matchingArguments blueprints selector =
    [ (blueprint, validator, argument)
    | blueprint <- blueprints
    , validator <- blueprintValidators blueprint
    , validatorMatches selector validator
    , Just argument <- [selectedArgument selector validator]
    ]

validatorMatches ::
    BlueprintArgumentSelector -> BlueprintValidator -> Bool
validatorMatches selector validator =
    case selectorValidatorTitle selector of
        Nothing ->
            True
        Just title ->
            validatorTitle validator == Just title

selectedArgument ::
    BlueprintArgumentSelector -> BlueprintValidator -> Maybe BlueprintArgument
selectedArgument selector =
    case selectorArgumentKind selector of
        BlueprintDatum ->
            validatorDatum
        BlueprintRedeemer ->
            validatorRedeemer

matchLabel :: Blueprint -> BlueprintValidator -> Text
matchLabel blueprint validator =
    case validatorTitle validator of
        Just title ->
            title
        Nothing ->
            preambleTitle (blueprintPreamble blueprint)

resolveBlueprintSchema ::
    Blueprint -> BlueprintSchema -> Either BlueprintMatchError BlueprintSchema
resolveBlueprintSchema blueprint =
    go Set.empty
  where
    go seen schema =
        case schemaKind schema of
            SchemaReference reference
                | reference `Set.member` seen ->
                    Left (BlueprintDefinitionCycle reference)
                | otherwise ->
                    case Map.lookup reference (blueprintDefinitions blueprint) of
                        Nothing ->
                            Left (BlueprintDefinitionMissing reference)
                        Just definition ->
                            go (Set.insert reference seen) definition
            SchemaConstructor index fields ->
                BlueprintSchema (schemaTitle schema)
                    . SchemaConstructor index
                    <$> traverse (go seen) fields
            SchemaInteger ->
                Right schema
            SchemaBytes ->
                Right schema

instance FromJSON Blueprint where
    parseJSON =
        withObject "Blueprint" $ \value ->
            Blueprint
                <$> value .: "preamble"
                <*> value .:? "validators" .!= []
                <*> value .:? "definitions" .!= Map.empty

instance FromJSON BlueprintPreamble where
    parseJSON =
        withObject "BlueprintPreamble" $ \value ->
            BlueprintPreamble
                <$> value .: "title"
                <*> value .: "plutusVersion"

instance FromJSON BlueprintValidator where
    parseJSON =
        withObject "BlueprintValidator" $ \value ->
            BlueprintValidator
                <$> value .:? "title"
                <*> value .:? "datum"
                <*> value .:? "redeemer"

instance FromJSON BlueprintArgument where
    parseJSON =
        withObject "BlueprintArgument" $ \value ->
            BlueprintArgument
                <$> value .:? "title"
                <*> value .: "schema"

instance FromJSON BlueprintSchema where
    parseJSON =
        withObject "BlueprintSchema" $ \value -> do
            title <- value .:? "title"
            kind <- schemaKindFromObject value
            pure
                BlueprintSchema
                    { schemaTitle = title
                    , schemaKind = kind
                    }

schemaKindFromObject ::
    Object -> Parser BlueprintSchemaKind
schemaKindFromObject value = do
    reference <- value .:? "$ref"
    case reference of
        Just ref ->
            SchemaReference <$> definitionReference ref
        Nothing -> do
            dataType <- value .: "dataType"
            case dataType :: Text of
                "integer" ->
                    pure SchemaInteger
                "bytes" ->
                    pure SchemaBytes
                "constructor" ->
                    SchemaConstructor
                        <$> value .: "index"
                        <*> value .:? "fields" .!= []
                unknown ->
                    fail
                        ( "unsupported Plutus blueprint dataType: "
                            <> Text.unpack unknown
                        )

definitionReference :: Text -> Parser Text
definitionReference reference =
    case Text.stripPrefix "#/definitions/" reference of
        Just definition
            | not (Text.null definition) ->
                pure definition
        _ ->
            fail
                ( "unsupported Plutus blueprint reference: "
                    <> Text.unpack reference
                )
