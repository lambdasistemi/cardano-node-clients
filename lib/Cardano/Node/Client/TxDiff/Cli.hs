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
    , txDiffCliHumanRenderOptions :: HumanRenderOptions
    , txDiffCliLeftPath :: FilePath
    , txDiffCliRightPath :: FilePath
    }
    deriving stock (Eq, Show)

newtype TxDiffCliError = TxDiffCliUsageError String
    deriving stock (Eq, Show)

parseTxDiffCliArgs :: [String] -> Either TxDiffCliError TxDiffCliOptions
parseTxDiffCliArgs =
    go [] defaultHumanRenderOptions
  where
    go blueprintPaths renderOptions ("--blueprint" : blueprintPath : rest) =
        go (blueprintPath : blueprintPaths) renderOptions rest
    go _ _ ["--blueprint"] =
        Left (TxDiffCliUsageError "missing value for --blueprint")
    go blueprintPaths renderOptions ("--render" : value : rest) =
        case parseRenderShape value of
            Left err ->
                Left err
            Right renderShape ->
                go
                    blueprintPaths
                    renderOptions{humanRenderShape = renderShape}
                    rest
    go _ _ ["--render"] =
        Left (TxDiffCliUsageError "missing value for --render")
    go blueprintPaths renderOptions ("--tree-art" : value : rest) =
        case parseTreeArt value of
            Left err ->
                Left err
            Right treeArt ->
                go
                    blueprintPaths
                    renderOptions{humanTreeArt = treeArt}
                    rest
    go _ _ ["--tree-art"] =
        Left (TxDiffCliUsageError "missing value for --tree-art")
    go blueprintPaths renderOptions [leftPath, rightPath] =
        Right
            TxDiffCliOptions
                { txDiffCliBlueprintPaths = reverse blueprintPaths
                , txDiffCliHumanRenderOptions = renderOptions
                , txDiffCliLeftPath = leftPath
                , txDiffCliRightPath = rightPath
                }
    go _ _ _ =
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
        <> " [--blueprint FILE ...] TX_A TX_B"
