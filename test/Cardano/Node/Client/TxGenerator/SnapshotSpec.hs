{- |
Module      : Cardano.Node.Client.TxGenerator.SnapshotSpec
Description : Unit tests for the snapshot percentiles
License     : Apache-2.0

Pins the nearest-rank percentile calculation in
'Cardano.Node.Client.TxGenerator.Snapshot.percentiles'.

The CBOR-decode side ('decodeIdxTxOut') is exercised
end-to-end by the T014 snapshot E2E spec — there is no
straightforward way to construct an indexer-encoded
TxOut at unit-test scope without pulling in the full
ledger machinery.
-}
module Cardano.Node.Client.TxGenerator.SnapshotSpec (spec) where

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Node.Client.TxGenerator.Snapshot (percentiles)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
 )

spec :: Spec
spec = describe "TxGenerator.Snapshot" $ do
    describe "percentiles" $ do
        it "returns Nothing on the empty list" $
            percentiles [] `shouldBe` Nothing

        it "single element: every percentile equals it" $
            percentiles [Coin 42]
                `shouldBe` Just (Coin 42, Coin 42, Coin 42)

        it "[1..10] yields p10 = 1, p50 = 5, p90 = 9" $
            percentiles (fmap Coin [1 .. 10])
                `shouldBe` Just (Coin 1, Coin 5, Coin 9)

        it "is order-invariant" $ do
            let unsorted =
                    fmap
                        Coin
                        [7, 3, 9, 1, 5, 10, 6, 2, 4, 8]
                sortedExpected =
                    percentiles (fmap Coin [1 .. 10])
            percentiles unsorted `shouldBe` sortedExpected

        it "duplicates are honoured" $ do
            -- 100 copies of 1, 100 of 5, 100 of 9.
            let xs =
                    fmap
                        Coin
                        ( replicate 100 1
                            <> replicate 100 5
                            <> replicate 100 9
                        )
            -- p10 falls in the first block, p50 in the
            -- middle, p90 in the third.
            case percentiles xs of
                Just (Coin a, Coin b, Coin c) -> do
                    a `shouldBe` 1
                    b `shouldBe` 5
                    c `shouldBe` 9
                Nothing -> error "expected Just"

        it "p10 ≤ p50 ≤ p90 for any non-empty input" $ do
            let xs =
                    fmap
                        Coin
                        [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
            case percentiles xs of
                Just (Coin a, Coin b, Coin c) -> do
                    a <= b `shouldBe` True
                    b <= c `shouldBe` True
                Nothing -> error "expected Just"
