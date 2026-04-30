{- |
Module      : Main
Description : cardano-adversary daemon entry point (PR B scaffold)
License     : Apache-2.0

CLI parsing only; everything else lives in
'Cardano.Node.Client.Adversary.Daemon.runDaemon'. CLI shape mirrors
@specs/036-cardano-adversary/spec.md@ and is the same idiom as
@cardano-tx-generator@.

Real flag parsing arrives with T006. T001 only ships a placeholder
that prints a usage line and exits 0 so the executable is buildable
end-to-end as soon as the cabal target lands.
-}
module Main (main) where

import System.IO (hPutStrLn, stderr)

main :: IO ()
main = hPutStrLn stderr "cardano-adversary: scaffold (see specs/036-cardano-adversary)"
