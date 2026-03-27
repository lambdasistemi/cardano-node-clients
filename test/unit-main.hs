module Main (main) where

import Test.Hspec (hspec)

import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec SampleFibonacciSpec.spec
