module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.BalanceSpec qualified as BalanceSpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    SampleFibonacciSpec.spec
    BalanceSpec.spec
