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
    diffConwayTxInput,
    diffNodeHasChanges,
    renderDiffNodeHuman,
 )
import Data.ByteString qualified as BS
import Data.Text.IO qualified as TextIO
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [leftPath, rightPath] ->
            runDiff leftPath rightPath
        _ ->
            dieUsage

runDiff :: FilePath -> FilePath -> IO ()
runDiff leftPath rightPath = do
    left <- BS.readFile leftPath
    right <- BS.readFile rightPath
    case diffConwayTxInput left right of
        Left err -> do
            hPutStrLn stderr ("tx-diff: failed to decode input: " <> show err)
            exitFailure
        Right diff -> do
            TextIO.putStr (renderDiffNodeHuman diff)
            if diffNodeHasChanges diff
                then exitFailure
                else exitSuccess

dieUsage :: IO a
dieUsage = do
    prog <- getProgName
    hPutStrLn stderr $ "Usage: " <> prog <> " TX_A TX_B"
    exitFailure
