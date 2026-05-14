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
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, (.!=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
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
    | SchemaAnyOf [BlueprintSchema]
    | SchemaList [BlueprintSchema]
    | SchemaListOf BlueprintSchema
    | SchemaData
    | SchemaReference Text
    deriving stock (Eq, Show)

parseBlueprintJSON :: LBS.ByteString -> Either String Blueprint
parseBlueprintJSON =
    eitherDecode

blueprintDataDecoder ::
    [Blueprint] -> TxDiffDataSelector -> Data ConwayEra -> Either Text OpenValue
blueprintDataDecoder blueprints selector datum =
    decodeMatchingBlueprintArgument
        blueprints
        (blueprintArgumentSelector selector)
        datum

decodeMatchingBlueprintArgument ::
    [Blueprint] ->
    BlueprintArgumentSelector ->
    Data ConwayEra ->
    Either Text OpenValue
decodeMatchingBlueprintArgument blueprints selector datum =
    case matches of
        [] ->
            Left (Text.pack (show (BlueprintMatchFallback BlueprintArgumentMissing)))
        _ ->
            case decodedMatches of
                [(_, value)] ->
                    Right value
                [] ->
                    Left (Text.intercalate "; " failedMatches)
                multiple ->
                    Left $
                        Text.pack $
                            show $
                                BlueprintMatchFallback $
                                    BlueprintArgumentAmbiguous (map fst multiple)
  where
    matches =
        matchingArguments blueprints selector
    attempts =
        [ ( matchLabel blueprint validator
          , case resolveBlueprintSchema blueprint (argumentSchema argument) of
                Left err ->
                    Left (Text.pack (show (BlueprintMatchFallback err)))
                Right schema ->
                    case decodeBlueprintData schema datum of
                        Left err ->
                            Left (Text.pack (show (BlueprintDataFallback err)))
                        Right value ->
                            Right value
          )
        | (blueprint, validator, argument) <- matches
        ]
    decodedMatches =
        [ (label, value)
        | (label, Right value) <- attempts
        ]
    failedMatches =
        [ label <> ": " <> reason
        | (label, Left reason) <- attempts
        ]

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
        SchemaAnyOf alternatives ->
            decodeAnyOf alternatives value
        SchemaList fields ->
            case value of
                PLC.List values
                    | length fields /= length values ->
                        Left
                            BlueprintFieldCountMismatch
                                { expectedFieldCount = length fields
                                , actualFieldCount = length values
                                }
                    | otherwise ->
                        OpenArray
                            <$> traverse
                                (uncurry decodeBlueprintValue)
                                (zip fields values)
                _ ->
                    Left (BlueprintDataTypeMismatch "list")
        SchemaListOf item ->
            case value of
                PLC.List values ->
                    OpenArray <$> traverse (decodeBlueprintValue item) values
                _ ->
                    Left (BlueprintDataTypeMismatch "list")
        SchemaData ->
            Right (plutusDataOpenValue value)
        SchemaReference reference ->
            Left (BlueprintUnresolvedReference reference)
  where
    decodeField (index, (fieldSchema, fieldValue)) = do
        decodedValue <- decodeBlueprintValue fieldSchema fieldValue
        pure (fieldName index fieldSchema, decodedValue)

decodeAnyOf ::
    [BlueprintSchema] -> PLC.Data -> Either BlueprintDataError OpenValue
decodeAnyOf alternatives value =
    case successes of
        [decoded] ->
            Right decoded
        [] ->
            case alternatives of
                firstAlternative : _ ->
                    decodeBlueprintValue firstAlternative value
                [] ->
                    Left (BlueprintDataTypeMismatch "anyOf")
        _ ->
            Left (BlueprintDataTypeMismatch "ambiguous anyOf")
  where
    successes =
        [ decoded
        | alternative <- alternatives
        , Right decoded <- [decodeBlueprintValue alternative value]
        ]

plutusDataOpenValue :: PLC.Data -> OpenValue
plutusDataOpenValue (PLC.I integer) =
    OpenInteger integer
plutusDataOpenValue (PLC.B bytes) =
    OpenBytes (hexText bytes)
plutusDataOpenValue (PLC.List values) =
    OpenArray (map plutusDataOpenValue values)
plutusDataOpenValue (PLC.Map entries) =
    OpenArray
        [ OpenObject $
            Map.fromList
                [ ("key", plutusDataOpenValue key)
                , ("value", plutusDataOpenValue itemValue)
                ]
        | (key, itemValue) <- entries
        ]
plutusDataOpenValue (PLC.Constr index fields) =
    OpenObject $
        Map.fromList
            [ ("constructor", OpenInteger index)
            , ("fields", OpenArray (map plutusDataOpenValue fields))
            ]

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
            SchemaAnyOf alternatives ->
                BlueprintSchema (schemaTitle schema)
                    . SchemaAnyOf
                    <$> traverse (go seen) alternatives
            SchemaList fields ->
                BlueprintSchema (schemaTitle schema)
                    . SchemaList
                    <$> traverse (go seen) fields
            SchemaListOf item ->
                BlueprintSchema (schemaTitle schema)
                    . SchemaListOf
                    <$> go seen item
            SchemaInteger ->
                Right schema
            SchemaBytes ->
                Right schema
            SchemaData ->
                Right schema

instance FromJSON Blueprint where
    parseJSON =
        withObject "Blueprint" $ \value ->
            Blueprint
                <$> value .: "preamble"
                <*> value .:? "validators" .!= []
                <*> parseBlueprintDefinitions value

parseBlueprintDefinitions :: Object -> Parser (Map Text BlueprintSchema)
parseBlueprintDefinitions value = do
    definitions <- value .:? "definitions" .!= KeyMap.empty
    pure $
        Map.fromList
            [ (Key.toText key, schema)
            | (key, definitionValue) <- KeyMap.toList definitions
            , Right schema <- [parseEither parseJSON definitionValue]
            ]

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
        Nothing ->
            schemaKindBody value

schemaKindBody :: Object -> Parser BlueprintSchemaKind
schemaKindBody value = do
    alternatives <- value .:? "anyOf"
    case alternatives of
        Just schemas ->
            pure (SchemaAnyOf schemas)
        Nothing -> do
            dataType <- value .:? "dataType"
            case dataType :: Maybe Text of
                Nothing ->
                    pure SchemaData
                Just "integer" ->
                    pure SchemaInteger
                Just "bytes" ->
                    pure SchemaBytes
                Just "constructor" ->
                    SchemaConstructor
                        <$> value .: "index"
                        <*> value .:? "fields" .!= []
                Just "list" ->
                    listSchemaKind value
                Just unknown ->
                    fail
                        ( "unsupported Plutus blueprint dataType: "
                            <> Text.unpack unknown
                        )

listSchemaKind :: Object -> Parser BlueprintSchemaKind
listSchemaKind value = do
    items <- value .:? "items"
    case items of
        Nothing ->
            pure (SchemaListOf anyDataSchema)
        Just (Aeson.Array itemValues) ->
            SchemaList <$> traverse parseJSON (toList itemValues)
        Just itemValue ->
            SchemaListOf <$> parseJSON itemValue

anyDataSchema :: BlueprintSchema
anyDataSchema =
    BlueprintSchema
        { schemaTitle = Nothing
        , schemaKind = SchemaData
        }

definitionReference :: Text -> Parser Text
definitionReference reference =
    case Text.stripPrefix "#/definitions/" reference of
        Just definition
            | not (Text.null definition) ->
                pure (jsonPointerToken definition)
        _ ->
            fail
                ( "unsupported Plutus blueprint reference: "
                    <> Text.unpack reference
                )

jsonPointerToken :: Text -> Text
jsonPointerToken =
    Text.replace "~0" "~" . Text.replace "~1" "/"
