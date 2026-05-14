{- |
Module      : Main
Description : tx-diff executable entry point
License     : Apache-2.0

Thin CLI wrapper over 'Cardano.Node.Client.TxDiff'. It reads two encoded
Conway transaction inputs, prints the human renderer output, and exits with a
non-zero status when differences are present.
-}
module Main (main) where

import Cardano.Node.Client.TxDiff (
    CollapseRules,
    HumanRenderOptions (..),
    TxDiffOptions (..),
    defaultTxDiffOptions,
    diffConwayTxInputWith,
    diffNodeHasChanges,
    parseCollapseRulesYaml,
    renderDiffNodeHumanWith,
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint,
    blueprintDataDecoder,
    parseBlueprintJSON,
 )
import Cardano.Node.Client.TxDiff.Cli (
    TxDiffCliError (..),
    TxDiffCliOptions (..),
    parseTxDiffCliArgs,
    txDiffCliUsage,
 )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text.IO qualified as TextIO
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    either dieUsage runDiff (parseTxDiffCliArgs args)

runDiff :: TxDiffCliOptions -> IO ()
runDiff cliOptions = do
    blueprints <- traverse loadBlueprint (txDiffCliBlueprintPaths cliOptions)
    collapseRules <- traverse loadCollapseRules (txDiffCliCollapseRulesPath cliOptions)
    left <- BS.readFile leftPath
    right <- BS.readFile rightPath
    let options =
            defaultTxDiffOptions
                { txDiffDecodeData =
                    case blueprints of
                        [] ->
                            Nothing
                        _ ->
                            Just (blueprintDataDecoder blueprints)
                }
    case diffConwayTxInputWith options left right of
        Left err -> do
            hPutStrLn stderr ("tx-diff: failed to decode input: " <> show err)
            exitFailure
        Right diff -> do
            TextIO.putStr $
                renderDiffNodeHumanWith
                    ( (txDiffCliHumanRenderOptions cliOptions)
                        { humanCollapseRules = collapseRules
                        }
                    )
                    diff
            if diffNodeHasChanges diff
                then exitFailure
                else exitSuccess
  where
    leftPath =
        txDiffCliLeftPath cliOptions
    rightPath =
        txDiffCliRightPath cliOptions

loadBlueprint :: FilePath -> IO Blueprint
loadBlueprint blueprintPath = do
    input <- LBS.readFile blueprintPath
    case parseBlueprintJSON input of
        Left err -> do
            hPutStrLn
                stderr
                ("tx-diff: failed to decode blueprint " <> blueprintPath <> ": " <> err)
            exitFailure
        Right blueprint ->
            pure blueprint

loadCollapseRules :: FilePath -> IO CollapseRules
loadCollapseRules collapseRulesPath = do
    input <- BS.readFile collapseRulesPath
    case parseCollapseRulesYaml input of
        Left err -> do
            hPutStrLn
                stderr
                ( "tx-diff: failed to decode collapse rules "
                    <> collapseRulesPath
                    <> ": "
                    <> err
                )
            exitFailure
        Right rules ->
            pure rules

dieUsage :: TxDiffCliError -> IO a
dieUsage (TxDiffCliUsageError err) = do
    prog <- getProgName
    hPutStrLn stderr ("tx-diff: " <> err)
    hPutStrLn stderr (txDiffCliUsage prog)
    exitFailure
