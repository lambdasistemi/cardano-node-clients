module Cardano.Node.Client.BalanceSpec (spec) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck

import Cardano.Crypto.Hash (hashFromStringAsHex)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (
    ppTxFeeFixedL,
    ppTxFeePerByteL,
 )
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    mkBasicTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    StrictMaybe (..),
    TxIx (..),
 )
import Cardano.Ledger.Coin (
    Coin (..),
    CoinPerByte (..),
    compactCoinOrError,
 )
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (
    emptyPParams,
    getMinFeeTx,
 )
import Cardano.Ledger.Credential (
    Credential (KeyHashObj),
    StakeReference (StakeRefNull),
 )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Payment),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import PlutusCore.Data qualified as PLC

import Cardano.Node.Client.Balance (
    BalanceError (..),
    BalanceResult (..),
    balanceTx,
    computeScriptIntegrity,
    placeholderExUnits,
    spendingIndex,
 )

spec :: Spec
spec = describe "Balance helpers" $ do
    spendingIndexSpec
    computeScriptIntegritySpec
    placeholderExUnitsSpec
    balanceTxSpec

-- -----------------------------------------------------------
-- Test TxIn construction
-- -----------------------------------------------------------

{- | Make a TxIn from an Int (deterministic, unique).
| Deterministic TxIn from an Int.
Uses the int as the last 2 bytes of a 32-byte
hash, producing unique sorted TxIds.
-}
mkTxIn :: Int -> TxIn
mkTxIn n =
    let hexStr =
            replicate 60 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in TxIn (TxId (unsafeMakeSafeHash h)) (TxIx 0)
  where
    hexByte b =
        let (hi, lo) = b `divMod` 16
         in [hexDigit hi, hexDigit lo]
    hexDigit d
        | d < 10 = toEnum (fromEnum '0' + d)
        | otherwise = toEnum (fromEnum 'a' + d - 10)

-- | Deterministic testnet address from an Int.
mkAddr :: Int -> Addr
mkAddr n =
    let hexStr =
            replicate 52 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in Addr
            Testnet
            (KeyHashObj (KeyHash h :: KeyHash Payment))
            StakeRefNull
  where
    hexByte b =
        let (hi, lo) = b `divMod` 16
         in [hexDigit hi, hexDigit lo]
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
        mapM_
            ( \(tin, expected) ->
                spendingIndex tin s `shouldBe` expected
            )
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
    Redeemers $
        Map.singleton
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

-- -----------------------------------------------------------
-- balanceTx
-- -----------------------------------------------------------

balanceTxSpec :: Spec
balanceTxSpec =
    describe "balanceTx" $ do
        it "uses getMinFeeTx plus VKey padding" $ do
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 44))
                        & ppTxFeeFixedL .~ Coin 155381
                inputUtxos =
                    [
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            (inject (Coin 10_000_000))
                        )
                    ]
                template =
                    mkBasicTx $
                        mkBasicTxBody
                            & outputsTxBodyL
                                .~ StrictSeq.singleton
                                    ( mkBasicTxOut
                                        (mkAddr 2)
                                        (inject (Coin 3_000_000))
                                    )
            case balanceTx
                pp
                inputUtxos
                (mkAddr 3)
                template of
                Left err ->
                    expectationFailure (show err)
                Right BalanceResult{balancedTx = tx} -> do
                    let fee = tx ^. bodyTxL . feeTxBodyL
                        Coin exactFee =
                            getMinFeeTx pp tx 0
                        Coin feePerByte =
                            fromCompact $
                                unCoinPerByte $
                                    pp ^. ppTxFeePerByteL
                        expectedFee =
                            Coin (exactFee + 106 * feePerByte)
                        outs =
                            foldr
                                (:)
                                []
                                (tx ^. bodyTxL . outputsTxBodyL)
                    fee `shouldBe` expectedFee
                    last outs ^. coinTxOutL
                        `shouldBe` Coin
                            (10_000_000 - 3_000_000 - exactFee - 106 * feePerByte)

        it "returns InsufficientFee when exact fee exceeds available input" $ do
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 200))
                        & ppTxFeeFixedL .~ Coin 200_000
                inputUtxos =
                    [
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            (inject (Coin 1))
                        )
                    ]
                template = mkBasicTx mkBasicTxBody
            case balanceTx
                pp
                inputUtxos
                (mkAddr 2)
                template of
                Left (InsufficientFee required available) -> do
                    required `shouldSatisfy` (> available)
                    available `shouldBe` Coin 1
                Left FeeNotConverged ->
                    expectationFailure
                        "expected InsufficientFee"
                Right _ ->
                    expectationFailure
                        "expected InsufficientFee"
