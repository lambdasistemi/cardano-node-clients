{-# LANGUAGE OverloadedStrings #-}

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
    BlueprintPreamble (..),
    BlueprintSchema (..),
    BlueprintSchemaKind (..),
    BlueprintValidator (..),
    parseBlueprintJSON,
) where

import Data.Aeson (
    FromJSON (..),
    Object,
    eitherDecode,
    withObject,
    (.:),
    (.:?),
 )
import Data.Aeson.Types (Parser, (.!=))
import Data.ByteString.Lazy (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

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

parseBlueprintJSON :: ByteString -> Either String Blueprint
parseBlueprintJSON =
    eitherDecode

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
