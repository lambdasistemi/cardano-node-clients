{- |
Module      : Cardano.Node.Client.TxGenerator.FanoutSpec
Description : Unit tests for the K-output fan-out
License     : Apache-2.0

Pins the determinism + range invariants of
'Cardano.Node.Client.TxGenerator.Fanout.pickDestinations'.
-}
module Cardano.Node.Client.TxGenerator.FanoutSpec (spec) where

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Node.Client.TxGenerator.Fanout (
    Destination (..),
    pickDestinations,
 )
import Data.Set qualified as Set
import Data.Word (Word64, Word8)
import System.Random (mkStdGen)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "TxGenerator.Fanout" $ do
    describe "pickDestinations" $ do
        it "is deterministic: same inputs → byte-identical output" $ do
            let r1 =
                    pickDestinations
                        17
                        6
                        0.5
                        (Coin 60_000_000)
                        (Coin 1_000_000)
                        (mkStdGen 42)
                r2 =
                    pickDestinations
                        17
                        6
                        0.5
                        (Coin 60_000_000)
                        (Coin 1_000_000)
                        (mkStdGen 42)
            destsOf r1 `shouldBe` destsOf r2
            nextIdxOf r1 `shouldBe` nextIdxOf r2

        it "produces exactly K destinations" $ do
            let (dests, _, _) =
                    pickDestinations
                        17
                        8
                        0.5
                        (Coin 60_000_000)
                        (Coin 1_000_000)
                        (mkStdGen 42)
            length dests `shouldBe` 8

        it "every destination value is ≥ minUTxO" $ do
            let (dests, _, _) =
                    pickDestinations
                        17
                        6
                        0.5
                        (Coin 60_000_000)
                        (Coin 1_000_000)
                        (mkStdGen 42)
            all (\d -> destValue d >= Coin 1_000_000) dests
                `shouldBe` True

        it "every destination value is ≤ available `div` K" $ do
            let k = 6 :: Word8
                available = Coin 60_000_000
                upper =
                    Coin
                        ( unCoin available
                            `div` toInteger k
                        )
                (dests, _, _) =
                    pickDestinations
                        17
                        k
                        0.5
                        available
                        (Coin 1_000_000)
                        (mkStdGen 42)
            all (\d -> destValue d <= upper) dests
                `shouldBe` True

        it "sum of destination values is ≤ available" $ do
            let available = Coin 60_000_000
                (dests, _, _) =
                    pickDestinations
                        17
                        6
                        0.5
                        available
                        (Coin 1_000_000)
                        (mkStdGen 42)
                total =
                    Coin
                        ( sum
                            ( fmap
                                (unCoin . destValue)
                                dests
                            )
                        )
            total <= available `shouldBe` True

        it
            "fresh destinations get sequentially assigned indices \
            \starting at the input nextIdx"
            $ do
                let (dests, finalIdx, _) =
                        pickDestinations
                            50
                            6
                            1.0 -- always fresh
                            (Coin 60_000_000)
                            (Coin 1_000_000)
                            (mkStdGen 42)
                    freshIdxs =
                        [ destIndex d | d <- dests, destFresh d
                        ]
                freshIdxs `shouldBe` [50, 51, 52, 53, 54, 55]
                finalIdx `shouldBe` 56

        it
            "prob_fresh = 0 with non-empty population yields \
            \no fresh destinations and finalIdx unchanged"
            $ do
                let (dests, finalIdx, _) =
                        pickDestinations
                            50
                            6
                            0.0
                            (Coin 60_000_000)
                            (Coin 1_000_000)
                            (mkStdGen 42)
                any destFresh dests `shouldBe` False
                finalIdx `shouldBe` 50

        it
            "every existing-population destination index \
            \is < nextIdx0"
            $ do
                let nextIdx0 = 32 :: Word64
                    (dests, _, _) =
                        pickDestinations
                            nextIdx0
                            16
                            0.5
                            (Coin 100_000_000)
                            (Coin 1_000_000)
                            (mkStdGen 7)
                    existingIdxs =
                        [ destIndex d
                        | d <- dests
                        , not (destFresh d)
                        ]
                all (< nextIdx0) existingIdxs `shouldBe` True

        it
            "empty population (nextIdx0 = 0) forces all destinations \
            \fresh regardless of prob_fresh"
            $ do
                let (dests, finalIdx, _) =
                        pickDestinations
                            0
                            4
                            0.0 -- spec says reuse, but no one to reuse
                            (Coin 40_000_000)
                            (Coin 1_000_000)
                            (mkStdGen 99)
                all destFresh dests `shouldBe` True
                finalIdx `shouldBe` 4

        it
            "different seeds produce different value distributions \
            \(statistical)"
            $ do
                let totals =
                        [ totalOf
                            ( pickDestinations
                                17
                                6
                                0.5
                                (Coin 60_000_000)
                                (Coin 1_000_000)
                                (mkStdGen seed)
                            )
                        | seed <- [1 .. 32 :: Int]
                        ]
                -- 32 distinct seeds; sum-of-output-values
                -- should not all collapse to the same number
                -- (within rounding).
                Set.size (Set.fromList totals)
                    `shouldSatisfy` (>= 16)

destsOf :: ([Destination], a, b) -> [Destination]
destsOf (xs, _, _) = xs

nextIdxOf :: (a, Word64, b) -> Word64
nextIdxOf (_, n, _) = n

totalOf :: ([Destination], a, b) -> Integer
totalOf (xs, _, _) = sum (fmap (unCoin . destValue) xs)
