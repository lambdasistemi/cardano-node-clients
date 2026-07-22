{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.E2E.PV11GovernanceSpec
Description : E2E test for PV11 governance transition on devnet
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.PV11GovernanceSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Api.PParams (ppCostModelsL, ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..), natVersion)
import Cardano.Ledger.Plutus (Language (PlutusV3), getCostModelParams)
import Cardano.Ledger.Plutus.CostModels (costModelsValid)

import Cardano.Node.Client.E2E.Setup (
    DevnetConfig (..),
    TargetPV (..),
    defaultDevnetConfig,
    withDevnetConfig,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider (Provider, queryProtocolParams)

spec :: Spec
spec = describe "PV11 Governance Transition" $ do
    it "enacts PV11 transition with PlutusV3 cost models on devnet" $ do
        let cfg = defaultDevnetConfig{devnetTargetPV = PV11}
        withDevnetConfig cfg $ \lsq _ltxs -> do
            let provider = mkN2CProvider lsq
            verifyPV11 provider 10
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
