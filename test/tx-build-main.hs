module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.TxBuildGoldenSpec qualified as TxBuildGoldenSpec

main :: IO ()
main =
    hspec $ do
        BalanceSpec.spec
        TxBuildGoldenSpec.spec
