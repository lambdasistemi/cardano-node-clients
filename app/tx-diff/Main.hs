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
    TxDiffOptions (..),
    defaultTxDiffOptions,
    diffConwayTxInputWith,
    diffNodeHasChanges,
    renderDiffNodeHuman,
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint,
    blueprintDataDecoder,
    parseBlueprintJSON,
 )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text.IO qualified as TextIO
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

data CliOptions = CliOptions
    { cliBlueprintPaths :: [FilePath]
    , cliLeftPath :: FilePath
    , cliRightPath :: FilePath
    }

main :: IO ()
main = do
    args <- getArgs
    maybe dieUsage runDiff (parseArgs args)

parseArgs :: [String] -> Maybe CliOptions
parseArgs =
    go []
  where
    go blueprintPaths ("--blueprint" : blueprintPath : rest) =
        go (blueprintPath : blueprintPaths) rest
    go blueprintPaths [leftPath, rightPath] =
        Just
            CliOptions
                { cliBlueprintPaths = reverse blueprintPaths
                , cliLeftPath = leftPath
                , cliRightPath = rightPath
                }
    go _ _ =
        Nothing

runDiff :: CliOptions -> IO ()
runDiff cliOptions = do
    blueprints <- traverse loadBlueprint (cliBlueprintPaths cliOptions)
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
            TextIO.putStr (renderDiffNodeHuman diff)
            if diffNodeHasChanges diff
                then exitFailure
                else exitSuccess
  where
    leftPath =
        cliLeftPath cliOptions
    rightPath =
        cliRightPath cliOptions

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

dieUsage :: IO a
dieUsage = do
    prog <- getProgName
    hPutStrLn stderr $ "Usage: " <> prog <> " [--blueprint FILE ...] TX_A TX_B"
    exitFailure
