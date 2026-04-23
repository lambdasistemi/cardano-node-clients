module Main (main) where

import qualified Cardano.Ledger.Binary as L
import           WasmLedgerSmoke       (smokeVersion)

main :: IO ()
main = putStrLn ("cardano-ledger-binary version ref OK (" ++ show (L.getVersion64 smokeVersion) ++ ")")
