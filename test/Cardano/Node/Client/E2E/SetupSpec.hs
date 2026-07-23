{-# LANGUAGE OverloadedStrings #-}

module Cardano.Node.Client.E2E.SetupSpec (spec) where

import Data.Aeson (Value (..), decodeFileStrict)
import Data.Aeson.KeyMap qualified as KM
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Node.Client.E2E.Setup (
    DevnetConfig (..),
    TargetPV (..),
    defaultDevnetConfig,
 )

spec :: Spec
spec = describe "Cardano.Node.Client.E2E.Setup" $ do
    it "decodes pparams-pv11-mainnet.json fixture correctly" $ do
        mVal <- decodeFileStrict "e2e-test/fixtures/pparams-pv11-mainnet.json"
        case mVal of
            Just (Object top) -> do
                case (KM.lookup "protocolVersion" top, KM.lookup "costModels" top) of
                    (Just (Object pv), Just (Object cm)) -> do
                        case (KM.lookup "major" pv, KM.lookup "PlutusV3" cm) of
                            (Just (Number 11), Just (Array v3)) ->
                                length v3 `shouldBe` 350
                            other ->
                                error $ "Unexpected PV or PlutusV3: " <> show other
                    other ->
                        error $ "Missing protocolVersion or costModels: " <> show other
            _ -> error "Failed to parse JSON fixture"

    it "has backward-compatible defaultDevnetConfig" $ do
        defaultDevnetConfig
            `shouldBe` DevnetConfig
                { devnetTargetPV = PV10
                , devnetGenesisDir = Nothing
                }
