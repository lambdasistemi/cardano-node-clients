module Cardano.Node.Client.BalanceSpec (spec) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck

import Cardano.Crypto.Hash (hashFromStringAsHex)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (
    AsIx (..),
    fromPlutusScript,
    mkPlutusScript,
 )
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
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
    mkBasicTxOut,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    StrictMaybe (..),
    TxIx (..),
    boundRational,
 )
import Cardano.Ledger.Coin (
    Coin (..),
    CoinPerByte (..),
    compactCoinOrError,
 )
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.PParams (
    ppMinFeeRefScriptCostPerByteL,
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (
    Script,
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
    Plutus (..),
    PlutusBinary (..),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data qualified as PLC

import Cardano.Node.Client.Balance (
    BalanceError (..),
    BalanceResult (..),
    balanceTx,
    computeScriptIntegrity,
    placeholderExUnits,
    refScriptsSize,
    spendingIndex,
 )

spec :: Spec
spec = describe "Balance helpers" $ do
    spendingIndexSpec
    computeScriptIntegritySpec
    placeholderExUnitsSpec
    balanceTxSpec
    refScriptsSizeSpec
    balanceTxRefScriptFeeSpec

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
                []
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
                []
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

-- -----------------------------------------------------------
-- refScriptsSize + balanceTx ref-script fee accounting (#74)
-- -----------------------------------------------------------

{- | Compiled always-true Plutus V3 validator
(@validators/always_true.ak@). 215 bytes of CBOR
when wrapped as a Plutus V3 script.
-}
alwaysTrueHex :: BS8.ByteString
alwaysTrueHex =
    "58d501010029800aba2aba1aab9eaab9dab9a48888966002646465\
    \300130053754003300700398038012444b30013370e9000001c4c\
    \9289bae300a3009375400915980099b874800800e2646644944c0\
    \2c004c02cc030004c024dd5002456600266e1d200400389925130\
    \0a3009375400915980099b874801800e2646644944dd698058009\
    \805980600098049baa0048acc004cdc3a40100071324a26014601\
    \26ea80122646644944dd698058009805980600098049baa004401\
    \c8039007200e401c3006300700130060013003375400d149a26ca\
    \c8009"

alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            either error id $
                Base16.decode (BS8.filter (/= '\n') alwaysTrueHex)
        plutus = Plutus @PlutusV3 (PlutusBinary (SBS.toShort bytes))
     in maybe
            (error "alwaysTrueScript: mkPlutusScript")
            fromPlutusScript
            (mkPlutusScript plutus)

scriptByteLen :: Int
scriptByteLen = 215 -- 430 hex chars / 2

refScriptsSizeSpec :: Spec
refScriptsSizeSpec =
    describe "refScriptsSize" $ do
        it "returns 0 when no UTxOs are passed" $
            refScriptsSize Set.empty [] `shouldBe` 0
        it "returns 0 when the body has no ref inputs" $ do
            let utxoIn = mkTxIn 1
                refUtxo =
                    mkBasicTxOut (mkAddr 1) (inject (Coin 5_000_000))
                        & referenceScriptTxOutL .~ SJust alwaysTrueScript
            refScriptsSize Set.empty [(utxoIn, refUtxo)]
                `shouldBe` 0
        it "sums Plutus script bytes for matching ref inputs" $ do
            let utxoIn = mkTxIn 1
                refUtxo =
                    mkBasicTxOut (mkAddr 1) (inject (Coin 5_000_000))
                        & referenceScriptTxOutL .~ SJust alwaysTrueScript
            refScriptsSize
                (Set.singleton utxoIn)
                [(utxoIn, refUtxo)]
                `shouldBe` scriptByteLen
        it "ignores UTxOs whose TxIn isn't in the body's ref-input set" $ do
            let utxoIn = mkTxIn 1
                otherIn = mkTxIn 2
                refUtxo =
                    mkBasicTxOut (mkAddr 1) (inject (Coin 5_000_000))
                        & referenceScriptTxOutL .~ SJust alwaysTrueScript
            refScriptsSize
                (Set.singleton otherIn)
                [(utxoIn, refUtxo)]
                `shouldBe` 0

balanceTxRefScriptFeeSpec :: Spec
balanceTxRefScriptFeeSpec =
    describe "balanceTx ref-script fee accounting"
        $ it
            "fee with refUtxos exceeds fee without by ≈ scriptBytes × minFeeRefScriptCostPerByte"
        $ do
            let costPerByte = 44 :: Integer
                interval =
                    fromMaybe
                        (error "boundRational")
                        (boundRational (toRational costPerByte))
                pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 44))
                        & ppTxFeeFixedL .~ Coin 155381
                        & ppMinFeeRefScriptCostPerByteL .~ interval
                refIn = mkTxIn 99
                refUtxo =
                    mkBasicTxOut (mkAddr 9) (inject (Coin 5_000_000))
                        & referenceScriptTxOutL
                            .~ SJust alwaysTrueScript
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
                            & referenceInputsTxBodyL
                                .~ Set.singleton refIn
            feeWith <- runBalance pp inputUtxos [(refIn, refUtxo)] template
            feeWithout <- runBalance pp inputUtxos [] template
            let Coin gap =
                    Coin
                        ( let Coin a = feeWith
                              Coin b = feeWithout
                           in a - b
                        )
                expected =
                    fromIntegral scriptByteLen * costPerByte
            gap `shouldBe` expected
  where
    runBalance pp ins refs tx =
        case balanceTx pp ins refs (mkAddr 3) tx of
            Left err -> do
                expectationFailure (show err)
                pure (Coin 0)
            Right BalanceResult{balancedTx = bal} ->
                pure (bal ^. bodyTxL . feeTxBodyL)
