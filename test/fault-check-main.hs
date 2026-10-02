{- |
Module      : Main
Description : Run one asset-query guard example and classify its result
License     : Apache-2.0

The runner behind the fault checks (@nix run .#fault-asset-matching@,
@nix run .#fault-snapshot-binding@). It runs exactly one example of
the asset-query guards, named by its full hspec path, prints one
outcome token on stdout and exits with its code (see
"Cardano.Node.Client.UTxOIndexer.FaultCheck"): @KILLED@ 0,
@SURVIVED@ 3, @SETUP-FAILURE:\<reason\>@ 2. The failure detail goes
to stderr.

The fault checks build this runner from a patched copy of the
production source; built from the unpatched source it is the same
runner with the fault removed.
-}
module Main (main) where

import Cardano.Node.Client.UTxOIndexer.AssetIndexSpec qualified as AssetIndexSpec
import Cardano.Node.Client.UTxOIndexer.FaultCheck (
    Outcome (..),
    exitCodeOf,
    render,
    runExample,
 )
import Cardano.Node.Client.UTxOIndexer.IndexedViewSpec qualified as IndexedViewSpec
import Cardano.Node.Client.UTxOIndexer.SocketReadViewSpec qualified as SocketReadViewSpec
import Control.Monad (unless)
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    (outcome, detail) <- case args of
        [example] -> runExample (AssetIndexSpec.spec >> IndexedViewSpec.spec >> SocketReadViewSpec.spec) example
        _ -> pure (SetupFailure "usage", "")
    unless (null detail) $ hPutStrLn stderr detail
    putStrLn (render outcome)
    exitWith (exitCodeOf outcome)
