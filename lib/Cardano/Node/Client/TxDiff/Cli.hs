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
    parseTxDiffCliArgs,
    txDiffCliUsage,
) where

import Cardano.Node.Client.TxDiff (
    HumanRenderOptions (..),
    RenderShape (..),
    TreeArt (..),
    defaultHumanRenderOptions,
 )

data TxDiffCliOptions = TxDiffCliOptions
    { txDiffCliBlueprintPaths :: [FilePath]
    , txDiffCliCollapseRulesPath :: Maybe FilePath
    , txDiffCliHumanRenderOptions :: HumanRenderOptions
    , txDiffCliLeftPath :: FilePath
    , txDiffCliRightPath :: FilePath
    }
    deriving stock (Eq, Show)

newtype TxDiffCliError = TxDiffCliUsageError String
    deriving stock (Eq, Show)

parseTxDiffCliArgs :: [String] -> Either TxDiffCliError TxDiffCliOptions
parseTxDiffCliArgs =
    go [] Nothing defaultHumanRenderOptions
  where
    go blueprintPaths collapseRulesPath renderOptions ("--blueprint" : blueprintPath : rest) =
        go (blueprintPath : blueprintPaths) collapseRulesPath renderOptions rest
    go _ _ _ ["--blueprint"] =
        Left (TxDiffCliUsageError "missing value for --blueprint")
    go blueprintPaths _ renderOptions ("--collapse-rules" : collapseRulesPath : rest) =
        go blueprintPaths (Just collapseRulesPath) renderOptions rest
    go _ _ _ ["--collapse-rules"] =
        Left (TxDiffCliUsageError "missing value for --collapse-rules")
    go blueprintPaths collapseRulesPath renderOptions ("--render" : value : rest) =
        case parseRenderShape value of
            Left err ->
                Left err
            Right renderShape ->
                go
                    blueprintPaths
                    collapseRulesPath
                    renderOptions{humanRenderShape = renderShape}
                    rest
    go _ _ _ ["--render"] =
        Left (TxDiffCliUsageError "missing value for --render")
    go blueprintPaths collapseRulesPath renderOptions ("--tree-art" : value : rest) =
        case parseTreeArt value of
            Left err ->
                Left err
            Right treeArt ->
                go
                    blueprintPaths
                    collapseRulesPath
                    renderOptions{humanTreeArt = treeArt}
                    rest
    go _ _ _ ["--tree-art"] =
        Left (TxDiffCliUsageError "missing value for --tree-art")
    go blueprintPaths collapseRulesPath renderOptions [leftPath, rightPath] =
        Right
            TxDiffCliOptions
                { txDiffCliBlueprintPaths = reverse blueprintPaths
                , txDiffCliCollapseRulesPath = collapseRulesPath
                , txDiffCliHumanRenderOptions = renderOptions
                , txDiffCliLeftPath = leftPath
                , txDiffCliRightPath = rightPath
                }
    go _ _ _ _ =
        Left (TxDiffCliUsageError "expected TX_A TX_B")

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
        <> " [--blueprint FILE ...] TX_A TX_B"
