{-# LANGUAGE NumericUnderscores #-}

module Cardano.Node.Client.E2E.BalanceSpec (spec) where

import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.TxIn (TxIn)

import Cardano.Node.Client.Balance (
    FeeLoopError (..),
    balanceFeeLoop,
 )
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
    withDevnet,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider (Provider (..))

spec :: Spec
spec = around withProviderAndParams $ do
    describe "balanceFeeLoop" $ do
        it "converges for a single output" singleOutput
        it "converges for multiple outputs" multiOutput
        it "reports negative refund" negativeRefund
        it "fee ≥ estimated min fee" feeIsSufficient

type Env = (PParams ConwayEra, Addr, [(TxIn, TxOut ConwayEra)])

withProviderAndParams :: (Env -> IO ()) -> IO ()
withProviderAndParams action =
    withDevnet $ \lsq _ltxs -> do
        let prov = mkN2CProvider lsq
        pp <- queryProtocolParams prov
        utxos <- queryUTxOs prov genesisAddr
        action (pp, genesisAddr, utxos)

-- | Fee converges with a single conservation output.
singleOutput :: Env -> IO ()
singleOutput (pp, addr, utxos) = do
    (seedIn, seedOut) <- case utxos of
        (u : _) -> pure u
        [] -> fail "no UTxOs"
    let
        Coin inputVal = seedOut ^. coinTxOutL
        tip = 100_000
        mkOutputs (Coin fee) =
            let refund = inputVal - fee - tip
             in if refund < 0
                    then Left "insufficient"
                    else
                        Right $
                            StrictSeq.singleton $
                                mkBasicTxOut
                                    addr
                                    (inject (Coin refund))
        template =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.singleton seedIn
                    & collateralInputsTxBodyL
                        .~ Set.singleton seedIn
                )
    case balanceFeeLoop pp mkOutputs 1 [] template of
        Left err -> fail $ "balanceFeeLoop: " <> show err
        Right tx -> do
            let Coin fee = tx ^. bodyTxL . feeTxBodyL
            fee `shouldSatisfy` (> 0)
            -- Verify conservation: input = output + fee + tip
            let outs = tx ^. bodyTxL . outputsTxBodyL
                Coin outVal =
                    foldl
                        (\(Coin a) o -> let Coin c = o ^. coinTxOutL in Coin (a + c))
                        (Coin 0)
                        outs
            (outVal + fee + tip) `shouldBe` inputVal

-- | Fee converges with 5 outputs (different tx size).
multiOutput :: Env -> IO ()
multiOutput (pp, addr, utxos) = do
    (seedIn, seedOut) <- case utxos of
        (u : _) -> pure u
        [] -> fail "no UTxOs"
    let
        Coin inputVal = seedOut ^. coinTxOutL
        n = 5
        tipPerOutput = 50_000
        mkOutputs (Coin fee) =
            let totalRefund = inputVal - fee - n * tipPerOutput
                perOutput = totalRefund `div` n
                remainder = totalRefund `mod` n
             in if totalRefund < 0
                    then Left "insufficient"
                    else
                        Right $
                            StrictSeq.fromList
                                [ mkBasicTxOut
                                    addr
                                    ( inject
                                        ( Coin
                                            ( perOutput
                                                + if i == (0 :: Integer)
                                                    then remainder
                                                    else 0
                                            )
                                        )
                                    )
                                | i <- [0 .. n - 1]
                                ]
        template =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.singleton seedIn
                    & collateralInputsTxBodyL
                        .~ Set.singleton seedIn
                )
    case balanceFeeLoop pp mkOutputs 1 [] template of
        Left err -> fail $ "balanceFeeLoop: " <> show err
        Right tx -> do
            let Coin fee = tx ^. bodyTxL . feeTxBodyL
                outs = tx ^. bodyTxL . outputsTxBodyL
                Coin outVal =
                    foldl
                        (\(Coin a) o -> let Coin c = o ^. coinTxOutL in Coin (a + c))
                        (Coin 0)
                        outs
            fee `shouldSatisfy` (> 0)
            -- Conservation: input = outputs + fee + tips
            (outVal + fee + n * tipPerOutput) `shouldBe` inputVal

-- | Output function returning Left propagates as OutputError.
negativeRefund :: Env -> IO ()
negativeRefund (pp, _addr, utxos) = do
    (seedIn, _) <- case utxos of
        (u : _) -> pure u
        [] -> fail "no UTxOs"
    let
        -- Always fail regardless of fee
        mkOutputs _ = Left "not enough funds"
        template =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.singleton seedIn
                )
    balanceFeeLoop pp mkOutputs 1 [] template
        `shouldBe` Left (OutputError "not enough funds")

-- | The converged fee is ≥ the estimated minimum.
feeIsSufficient :: Env -> IO ()
feeIsSufficient (pp, addr, utxos) = do
    (seedIn, seedOut) <- case utxos of
        (u : _) -> pure u
        [] -> fail "no UTxOs"
    let
        Coin inputVal = seedOut ^. coinTxOutL
        mkOutputs (Coin fee) =
            let refund = inputVal - fee
             in if refund < 0
                    then Left "insufficient"
                    else
                        Right $
                            StrictSeq.singleton $
                                mkBasicTxOut
                                    addr
                                    (inject (Coin refund))
        template =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.singleton seedIn
                    & collateralInputsTxBodyL
                        .~ Set.singleton seedIn
                )
    case balanceFeeLoop pp mkOutputs 1 [] template of
        Left err -> fail $ "balanceFeeLoop: " <> show err
        Right tx -> do
            let Coin fee = tx ^. bodyTxL . feeTxBodyL
                -- Re-estimate to verify
                Coin minFee =
                    estimateMinFeeTx pp tx 1 0 0
            fee `shouldSatisfy` (>= minFee)
