{-# LANGUAGE NumericUnderscores #-}

module Cardano.Node.Client.BalanceSpec (spec) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Test.Hspec
import Test.QuickCheck

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose (..)
    )
import Cardano.Ledger.Core (emptyPParams)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Crypto.Hash (hashFromStringAsHex)
import PlutusCore.Data qualified as PLC

import Cardano.Node.Client.Balance
    ( computeScriptIntegrity
    , placeholderExUnits
    , spendingIndex
    )

spec :: Spec
spec = describe "Balance helpers" $ do
    spendingIndexSpec
    computeScriptIntegritySpec
    placeholderExUnitsSpec

-- -----------------------------------------------------------
-- Test TxIn construction
-- -----------------------------------------------------------

-- | Make a TxIn from an Int (deterministic, unique).
-- | Deterministic TxIn from an Int.
-- Uses the int as the last 2 bytes of a 32-byte
-- hash, producing unique sorted TxIds.
mkTxIn :: Int -> TxIn
mkTxIn n =
    let hexStr =
            replicate 60 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
    in  TxIn (TxId (unsafeMakeSafeHash h)) (TxIx 0)
  where
    hexByte b =
        let (hi, lo) = b `divMod` 16
        in  [hexDigit hi, hexDigit lo]
    hexDigit d
        | d < 10 = toEnum (fromEnum '0' + d)
        | otherwise = toEnum (fromEnum 'a' + d - 10)

-- -----------------------------------------------------------
-- spendingIndex
-- -----------------------------------------------------------

spendingIndexSpec :: Spec
spendingIndexSpec = describe "spendingIndex" $ do
    it "returns 0 for a singleton set" $ do
        let tin = mkTxIn 1
            s = Set.singleton tin
        spendingIndex tin s `shouldBe` 0

    it "returns correct index for sorted position" $ do
        let tins = map mkTxIn [1 .. 5]
            s = Set.fromList tins
            sorted = Set.toAscList s
        mapM_ (\(tin, expected) ->
            spendingIndex tin s `shouldBe` expected)
            (zip sorted [0 ..])

    it "index < set size (property)" $
        property $
            forAll (choose (1, 20)) $ \n -> do
                let tins = map mkTxIn [1 .. n]
                    s = Set.fromList tins
                all
                    ( \tin ->
                        spendingIndex tin s
                            < fromIntegral (Set.size s)
                    )
                    tins

    it "is monotonic (property)" $
        property $
            forAll (choose (2, 15)) $ \n -> do
                let tins = map mkTxIn [1 .. n]
                    s = Set.fromList tins
                    sorted = Set.toAscList s
                    indices =
                        map (`spendingIndex` s) sorted
                indices == sort indices
                    && length (nub indices)
                        == length indices

    it "adding an element shifts later indices" $ do
        let tins = map mkTxIn [1, 3, 5]
            s = Set.fromList tins
            ix3 = spendingIndex (mkTxIn 3) s
            s' = Set.insert (mkTxIn 2) s
            ix3' = spendingIndex (mkTxIn 3) s'
        ix3' `shouldBe` ix3 + 1

-- -----------------------------------------------------------
-- computeScriptIntegrity
-- -----------------------------------------------------------

-- | Build a Redeemers with a spending entry.
mkRedeemers :: Integer -> Redeemers ConwayEra
mkRedeemers seed =
    Redeemers
        $ Map.singleton
            (ConwaySpending (AsIx 0))
            ( Data (PLC.I seed)
            , ExUnits 1000 10000
            )

computeScriptIntegritySpec :: Spec
computeScriptIntegritySpec =
    describe "computeScriptIntegrity" $ do
        it "returns SJust for non-empty redeemers" $ do
            let pp = emptyPParams @ConwayEra
                result =
                    computeScriptIntegrity
                        PlutusV3
                        pp
                        (mkRedeemers 42)
            case result of
                SJust _ -> pure ()
                SNothing ->
                    expectationFailure "expected SJust"

        it "is deterministic" $ do
            let pp = emptyPParams @ConwayEra
                r1 =
                    computeScriptIntegrity
                        PlutusV3
                        pp
                        (mkRedeemers 42)
                r2 =
                    computeScriptIntegrity
                        PlutusV3
                        pp
                        (mkRedeemers 42)
            r1 `shouldBe` r2

        it "different data ⇒ different hash" $ do
            let pp = emptyPParams @ConwayEra
                r1 =
                    computeScriptIntegrity
                        PlutusV3
                        pp
                        (mkRedeemers 1)
                r2 =
                    computeScriptIntegrity
                        PlutusV3
                        pp
                        (mkRedeemers 2)
            r1 `shouldNotBe` r2

-- -----------------------------------------------------------
-- placeholderExUnits
-- -----------------------------------------------------------

placeholderExUnitsSpec :: Spec
placeholderExUnitsSpec =
    describe "placeholderExUnits" $
        it "has zero mem and steps" $ do
            let ExUnits mem steps = placeholderExUnits
            mem `shouldBe` 0
            steps `shouldBe` 0
