{- |
Module      : Cardano.Node.Client.TxDiff.Cli
Description : tx-diff command-line option parsing.
License     : Apache-2.0

Pure parser for the `tx-diff` executable. Keeping parsing separate from file
IO guarantees invalid render flags fail before transaction inputs or
blueprints are read.
-}
module Cardano.Node.Client.TxDiff.Cli (
    TxDiffCliError (..),
    TxDiffCliOptions (..),
    TxDiffCliN2cConfig (..),
    TxDiffCliWeb2Config (..),
    parseTxDiffCliArgs,
    txDiffCliUsage,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Text.Read (readMaybe)

import Cardano.Node.Client.TxDiff (
    HumanRenderOptions (..),
    RenderShape (..),
    TreeArt (..),
    defaultHumanRenderOptions,
 )

data TxDiffCliN2cConfig = TxDiffCliN2cConfig
    { txDiffCliN2cSocket :: FilePath
    , txDiffCliN2cNetworkMagic :: Word32
    }
    deriving stock (Eq, Show)

data TxDiffCliWeb2Config = TxDiffCliWeb2Config
    { txDiffCliWeb2Url :: Text
    , txDiffCliWeb2ApiKeyFile :: Maybe FilePath
    -- ^ Path to a file whose contents (after stripping surrounding
    -- whitespace) are sent as the @project_id@ header. When 'Nothing',
    -- the executable falls back to the @TX_DIFF_WEB2_API_KEY@ environment
    -- variable; if that is also unset the request is sent without a key,
    -- which suits Blockfrost-compatible self-hosted endpoints.
    }
    deriving stock (Eq, Show)

data TxDiffCliOptions = TxDiffCliOptions
    { txDiffCliBlueprintPaths :: [FilePath]
    , txDiffCliCollapseRulesPath :: Maybe FilePath
    , txDiffCliHumanRenderOptions :: HumanRenderOptions
    , txDiffCliN2cResolver :: Maybe TxDiffCliN2cConfig
    , txDiffCliWeb2Resolver :: Maybe TxDiffCliWeb2Config
    , txDiffCliLeftPath :: FilePath
    , txDiffCliRightPath :: FilePath
    }
    deriving stock (Eq, Show)

newtype TxDiffCliError = TxDiffCliUsageError String
    deriving stock (Eq, Show)

parseTxDiffCliArgs :: [String] -> Either TxDiffCliError TxDiffCliOptions
parseTxDiffCliArgs args =
    do
        (acc, positional) <- go emptyAccumulator args
        case positional of
            [leftPath, rightPath] ->
                buildOptions acc leftPath rightPath
            _ ->
                Left (TxDiffCliUsageError "expected TX_A TX_B")
  where
    go acc ("--blueprint" : blueprintPath : rest) =
        go acc{accBlueprintPaths = blueprintPath : accBlueprintPaths acc} rest
    go _ ["--blueprint"] =
        Left (TxDiffCliUsageError "missing value for --blueprint")
    go acc ("--collapse-rules" : collapseRulesPath : rest) =
        go acc{accCollapseRulesPath = Just collapseRulesPath} rest
    go _ ["--collapse-rules"] =
        Left (TxDiffCliUsageError "missing value for --collapse-rules")
    go acc ("--render" : value : rest) = do
        renderShape <- parseRenderShape value
        let renderOptions = accRenderOptions acc
        go
            acc{accRenderOptions = renderOptions{humanRenderShape = renderShape}}
            rest
    go _ ["--render"] =
        Left (TxDiffCliUsageError "missing value for --render")
    go acc ("--tree-art" : value : rest) = do
        treeArt <- parseTreeArt value
        let renderOptions = accRenderOptions acc
        go acc{accRenderOptions = renderOptions{humanTreeArt = treeArt}} rest
    go _ ["--tree-art"] =
        Left (TxDiffCliUsageError "missing value for --tree-art")
    go acc ("--resolve-n2c" : path : rest) =
        go acc{accN2cSocket = Just path} rest
    go _ ["--resolve-n2c"] =
        Left (TxDiffCliUsageError "missing value for --resolve-n2c")
    go acc ("--network-magic" : value : rest) =
        case readMaybe value of
            Nothing ->
                Left
                    ( TxDiffCliUsageError $
                        "expected a non-negative integer for --network-magic, got: " <> value
                    )
            Just magic ->
                go acc{accNetworkMagic = Just magic} rest
    go _ ["--network-magic"] =
        Left (TxDiffCliUsageError "missing value for --network-magic")
    go acc ("--resolve-web2" : url : rest) =
        go acc{accWeb2Url = Just (Text.pack url)} rest
    go _ ["--resolve-web2"] =
        Left (TxDiffCliUsageError "missing value for --resolve-web2")
    go acc ("--web2-api-key-file" : path : rest) =
        go acc{accWeb2ApiKeyFile = Just path} rest
    go _ ["--web2-api-key-file"] =
        Left (TxDiffCliUsageError "missing value for --web2-api-key-file")
    go acc rest =
        Right (acc, rest)

    buildOptions acc leftPath rightPath = do
        n2c <- buildN2c acc
        web2 <- buildWeb2 acc
        Right
            TxDiffCliOptions
                { txDiffCliBlueprintPaths = reverse (accBlueprintPaths acc)
                , txDiffCliCollapseRulesPath = accCollapseRulesPath acc
                , txDiffCliHumanRenderOptions = accRenderOptions acc
                , txDiffCliN2cResolver = n2c
                , txDiffCliWeb2Resolver = web2
                , txDiffCliLeftPath = leftPath
                , txDiffCliRightPath = rightPath
                }

    buildN2c acc =
        case (accN2cSocket acc, accNetworkMagic acc) of
            (Nothing, Nothing) -> Right Nothing
            (Just socket, Just magic) ->
                Right (Just (TxDiffCliN2cConfig socket magic))
            (Just _, Nothing) ->
                Left
                    ( TxDiffCliUsageError
                        "--resolve-n2c also requires --network-magic"
                    )
            (Nothing, Just _) ->
                Left
                    ( TxDiffCliUsageError
                        "--network-magic also requires --resolve-n2c"
                    )

    buildWeb2 acc =
        case (accWeb2Url acc, accWeb2ApiKeyFile acc) of
            (Nothing, Nothing) -> Right Nothing
            (Just url, keyFile) ->
                Right (Just (TxDiffCliWeb2Config url keyFile))
            (Nothing, Just _) ->
                Left
                    ( TxDiffCliUsageError
                        "--web2-api-key-file requires --resolve-web2"
                    )

data Accumulator = Accumulator
    { accBlueprintPaths :: [FilePath]
    , accCollapseRulesPath :: Maybe FilePath
    , accRenderOptions :: HumanRenderOptions
    , accN2cSocket :: Maybe FilePath
    , accNetworkMagic :: Maybe Word32
    , accWeb2Url :: Maybe Text
    , accWeb2ApiKeyFile :: Maybe FilePath
    }

emptyAccumulator :: Accumulator
emptyAccumulator =
    Accumulator
        { accBlueprintPaths = []
        , accCollapseRulesPath = Nothing
        , accRenderOptions = defaultHumanRenderOptions
        , accN2cSocket = Nothing
        , accNetworkMagic = Nothing
        , accWeb2Url = Nothing
        , accWeb2ApiKeyFile = Nothing
        }

parseRenderShape :: String -> Either TxDiffCliError RenderShape
parseRenderShape "tree" =
    Right RenderTree
parseRenderShape "paths" =
    Right RenderPaths
parseRenderShape value =
    Left (TxDiffCliUsageError ("unsupported --render value: " <> value))

parseTreeArt :: String -> Either TxDiffCliError TreeArt
parseTreeArt "ascii" =
    Right TreeArtAscii
parseTreeArt "unicode" =
    Right TreeArtUnicode
parseTreeArt value =
    Left (TxDiffCliUsageError ("unsupported --tree-art value: " <> value))

txDiffCliUsage :: String -> String
txDiffCliUsage prog =
    "Usage: "
        <> prog
        <> " [--render tree|paths] [--tree-art ascii|unicode]"
        <> " [--collapse-rules FILE]"
        <> " [--blueprint FILE ...]"
        <> " [--resolve-n2c SOCKET --network-magic N]"
        <> " [--resolve-web2 URL [--web2-api-key-file PATH]]"
        <> " TX_A TX_B"
