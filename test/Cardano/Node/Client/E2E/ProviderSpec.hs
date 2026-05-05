{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.ProviderSpec
Description : E2E tests for the N2C Provider
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.ProviderSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Test.Hspec (
    Spec,
    around,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)

import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
    withDevnet,
 )
import Cardano.Node.Client.N2C.Provider (
    mkN2CProvider,
 )
import Cardano.Node.Client.Provider (
    Provider (..),
    queryProtocolParamsH,
    queryUTxOByTxInH,
    queryUTxOsAtH,
 )

spec :: Spec
spec =
    around withDevnet' $
        describe "Provider.N2C" $
            do
                it "queryProtocolParams returns valid PParams" $
                    \(lsq, _) -> do
                        let provider =
                                mkN2CProvider lsq
                        pp <-
                            queryProtocolParams provider
                        let maxTxSize =
                                pp ^. ppMaxTxSizeL
                        maxTxSize
                            `shouldSatisfy` (> 0)

                it "queryUTxOs returns genesis funds" $
                    \(lsq, _) -> do
                        let provider =
                                mkN2CProvider lsq
                        utxos <-
                            queryUTxOs
                                provider
                                genesisAddr
                        utxos
                            `shouldSatisfy` (not . null)

                it "withAcquired serves multiple queries through one handle" $
                    \(lsq, _) -> do
                        let provider =
                                mkN2CProvider lsq
                        (maxTxSize, byAddr, byTxIn) <-
                            withAcquired provider $ \handle -> do
                                pp <-
                                    queryProtocolParamsH handle
                                utxosAt <-
                                    queryUTxOsAtH
                                        handle
                                        (Set.singleton genesisAddr)
                                let txIns =
                                        Set.fromList $
                                            take
                                                1
                                                ( fst
                                                    <$> Map.findWithDefault
                                                        []
                                                        genesisAddr
                                                        utxosAt
                                                )
                                utxosByTxIn <-
                                    queryUTxOByTxInH
                                        handle
                                        txIns
                                pure
                                    ( pp ^. ppMaxTxSizeL
                                    , utxosAt
                                    , utxosByTxIn
                                    )
                        let addrUtxos =
                                Map.findWithDefault
                                    []
                                    genesisAddr
                                    byAddr
                            txIns =
                                Set.fromList $
                                    take 1 $
                                        fmap fst addrUtxos
                        maxTxSize
                            `shouldSatisfy` (> 0)
                        addrUtxos
                            `shouldSatisfy` (not . null)
                        Map.keysSet byTxIn
                            `shouldBe` txIns
  where
    withDevnet' action =
        withDevnet $ curry action
