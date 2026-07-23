{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.E2E.PV11GovernanceSpec
Description : E2E test for PV11 governance transition and Plomin builtin script execution on devnet
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.PV11GovernanceSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Api (coinTxOutL, txIdTx)
import Cardano.Ledger.Api.PParams (ppCostModelsL, ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..), TxIx (..), natVersion)
import Cardano.Ledger.Plutus (Language (PlutusV3), getCostModelParams)
import Cardano.Ledger.Plutus.CostModels (costModelsValid)
import Cardano.Ledger.TxIn (TxIn (..))

import Cardano.Node.Client.E2E.Devnet (addKeyWitness, genesisSignKey)
import Cardano.Node.Client.E2E.PlominScript (
    mkPlominLockTx,
    mkPlominSpendTx,
    plominScriptAddr,
 )
import Cardano.Node.Client.E2E.Setup (
    DevnetConfig (..),
    TargetPV (..),
    assertPV11Enacted,
    defaultDevnetConfig,
    genesisAddr,
    withDevnetConfig,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (Provider, queryProtocolParams, queryUTxOs)
import Cardano.Node.Client.Submitter (SubmitResult (..), submitTx)

spec :: Spec
spec = describe "PV11 Governance Transition" $ do
    it "enacts PV11 transition with PlutusV3 cost models on devnet" $ do
        let cfg = defaultDevnetConfig{devnetTargetPV = PV11}
        withDevnetConfig cfg $ \lsq _ltxs -> do
            let provider = mkN2CProvider lsq
            verifyPV11 provider 60

    it "asserts PV11 enactment via assertPV11Enacted" $ do
        let cfg = defaultDevnetConfig{devnetTargetPV = PV11}
        withDevnetConfig cfg $ \lsq _ltxs -> do
            let provider = mkN2CProvider lsq
            assertPV11Enacted provider

    it "executes and settles a transaction using Plomin-era builtin (xorByteString) on PV11 devnet" $ do
        let cfg = defaultDevnetConfig{devnetTargetPV = PV11}
        withDevnetConfig cfg $ \lsq ltxs -> do
            let provider = mkN2CProvider lsq
                submitter = mkN2CSubmitter ltxs

            utxos0 <- queryUTxOs provider genesisAddr
            case utxos0 of
                [] -> error "No initial UTxOs found at genesisAddr"
                (initTxIn, initTxOut) : _ -> do
                    let initCoin = initTxOut ^. coinTxOutL
                        lockTx = mkPlominLockTx initTxIn initCoin genesisAddr

                    res1 <- submitTx submitter lockTx
                    case res1 of
                        Submitted _ -> pure ()
                        Rejected err -> error $ "Lock tx rejected: " <> show err

                    threadDelay 2_000_000

                    scriptUtxos <- queryUTxOs provider plominScriptAddr
                    case scriptUtxos of
                        [] -> error "No UTxOs found at plominScriptAddr after lock tx"
                        (scriptTxIn, scriptTxOut) : _ -> do
                            pp <- queryProtocolParams provider
                            let scriptCoin = scriptTxOut ^. coinTxOutL
                                collateralTxIn = TxIn (txIdTx lockTx) (TxIx 1)
                                spendTx = addKeyWitness genesisSignKey $ mkPlominSpendTx scriptTxIn collateralTxIn pp scriptCoin genesisAddr

                            res2 <- submitTx submitter spendTx
                            case res2 of
                                Submitted _ -> pure ()
                                Rejected err -> error $ "Spend tx rejected: " <> show err

                            threadDelay 2_000_000

                            scriptUtxosAfter <- queryUTxOs provider plominScriptAddr
                            scriptUtxosAfter `shouldBe` []
  where
    verifyPV11 :: Provider IO -> Int -> IO ()
    verifyPV11 _provider 0 = error "verifyPV11: timed out waiting for PParams query"
    verifyPV11 provider atts = do
        ePP <- try @SomeException (queryProtocolParams provider)
        case ePP of
            Right pp -> do
                let ProtVer major _minor = pp ^. ppProtocolVersionL
                major `shouldBe` natVersion @11

                let cms = pp ^. ppCostModelsL
                    validCMs = costModelsValid cms
                case Map.lookup PlutusV3 validCMs of
                    Just cm -> length (getCostModelParams cm) `shouldBe` 350
                    Nothing -> error "PlutusV3 cost model not found in PParams"
            Left _err -> do
                threadDelay 2_000_000
                verifyPV11 provider (atts - 1)
