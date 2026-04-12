module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.TxBuildGoldenSpec qualified as TxBuildGoldenSpec
import Cardano.Node.Client.TxBuildSpec qualified as TxBuildSpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    SampleFibonacciSpec.spec
    BalanceSpec.spec
    TxBuildSpec.spec
    TxBuildGoldenSpec.spec
