{- |
Module      : Cardano.Node.Client.TxBuildSpec
Description : TxBuild DSL tests — Slice 1
License     : Apache-2.0

Tests for simple pub-key spend, payTo, collateral,
and draft assembly. Verifies inputs/outputs in
assembled Tx and that spend returns correct index.
-}
module Cardano.Node.Client.TxBuildSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (Tx)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    TxIx (..),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.TxIn (
    TxId (..),
    TxIn (..),
 )
import Cardano.Node.Client.TxBuild
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (
    Hash,
    HashAlgorithm,
    hashFromBytes,
 )
import Data.ByteString qualified as BS
import Data.Maybe (fromJust)
import Data.Word (Word8)

-- --------------------------------------------------
-- Test helpers
-- --------------------------------------------------

-- | Deterministic 32-byte hash.
mkHash32 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 31 0 ++ [n]

-- | Deterministic 28-byte hash.
mkHash28 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 27 0 ++ [n]

-- | Fake TxIn from a byte.
mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx (fromIntegral n))

-- | Fake address from a byte.
mkAddr :: Word8 -> Addr
mkAddr n =
    Addr
        Testnet
        (KeyHashObj (KeyHash (mkHash28 n)))
        StakeRefNull

-- --------------------------------------------------
-- Spec
-- --------------------------------------------------

spec :: Spec
spec = describe "TxBuild" $ do
    spendSpec
    payToSpec
    collateralSpec
    spendIndexSpec

spendSpec :: Spec
spendSpec =
    describe "spend" $ do
        it "adds TxIn to inputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <- spend (mkTxIn 1)
                        pure ()
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.member (mkTxIn 1) ins
                `shouldBe` True

        it "multiple spends all appear" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <- spend (mkTxIn 1)
                        _ <- spend (mkTxIn 2)
                        _ <- spend (mkTxIn 3)
                        pure ()
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.size ins `shouldBe` 3

payToSpec :: Spec
payToSpec =
    describe "payTo" $ do
        it "adds output to outputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <-
                            payTo
                                (mkAddr 1)
                                (inject (Coin 2_000_000))
                        pure ()
                outs =
                    tx ^. bodyTxL . outputsTxBodyL
            length outs `shouldBe` 1

        it "multiple payTo all appear in order" $
            do
                let tx =
                        draft emptyPParams $ do
                            _ <-
                                payTo
                                    (mkAddr 1)
                                    (inject (Coin 1_000_000))
                            _ <-
                                payTo
                                    (mkAddr 2)
                                    (inject (Coin 2_000_000))
                            pure ()
                    outs =
                        tx ^. bodyTxL . outputsTxBodyL
                length outs `shouldBe` 2

collateralSpec :: Spec
collateralSpec =
    describe "collateral" $ do
        it "adds to collateralInputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        collateral (mkTxIn 5)
                ins =
                    tx
                        ^. bodyTxL
                            . collateralInputsTxBodyL
            Set.member (mkTxIn 5) ins
                `shouldBe` True

        it "not in inputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        collateral (mkTxIn 5)
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.member (mkTxIn 5) ins
                `shouldBe` False

spendIndexSpec :: Spec
spendIndexSpec =
    describe "spend index" $ do
        it "returns 0 for single input" $ do
            let (tx, idx) =
                    runDraft $
                        spend (mkTxIn 1)
            idx `shouldBe` 0
            Set.size
                (tx ^. bodyTxL . inputsTxBodyL)
                `shouldBe` 1

        it "returns correct sorted indices" $ do
            -- mkTxIn 1 sorts before mkTxIn 2
            let (_, (i1, i2)) = runDraft $ do
                    a <- spend (mkTxIn 2)
                    b <- spend (mkTxIn 1)
                    pure (a, b)
            -- mkTxIn 1 is at index 0 (sorts first)
            -- mkTxIn 2 is at index 1
            i2 `shouldBe` 0
            i1 `shouldBe` 1

        it "interleaves pure computation" $ do
            let (_, result) = runDraft $ do
                    i <- spend (mkTxIn 1)
                    let doubled = i * 2
                    _ <- spend (mkTxIn 2)
                    pure doubled
            -- mkTxIn 1 is at index 0, doubled = 0
            result `shouldBe` 0

{- | Run draft and return both the Tx and the
program's result.
-}
runDraft ::
    TxBuild q e a -> (Tx ConwayEra, a)
runDraft prog =
    let initialTx = draft emptyPParams (pure ())
        (st1, _, _) = interpretWith initialTx prog
        tx1 = assembleTx st1
        (st2, a, _) = interpretWith tx1 prog
     in (assembleTx st2, a)
