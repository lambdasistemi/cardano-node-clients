{- |
Module      : Cardano.Node.Client.N2C.ProbeSpec
Description : Smoke tests for the probe's defaults
License     : Apache-2.0

The full E2E behaviour of 'waitForNodeReady' (against a
real cardano-node that's still loading its ChainDB) is
exercised by 'UTxOIndexerReconnectSpec'. Here we only
lock down the pure surface: 'defaultProbeConfig' values
match the documented defaults from
@quickstart.md § CLI surface@.
-}
module Cardano.Node.Client.N2C.ProbeSpec (spec) where

import Cardano.Node.Client.N2C.Probe (
    ProbeConfig (..),
    defaultProbeConfig,
 )
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "Cardano.Node.Client.N2C.Probe" $ do
    describe "defaultProbeConfig" $ do
        it "per-attempt timeout = 5_000 ms" $
            pcAttemptTimeoutMs defaultProbeConfig `shouldBe` 5_000
        it "between-attempts backoff base = 250 ms" $
            pcRetryBaseMs defaultProbeConfig `shouldBe` 250
        it "between-attempts backoff cap = 5_000 ms" $
            pcRetryMaxMs defaultProbeConfig `shouldBe` 5_000
        it "total timeout default is unbounded (Nothing)" $
            pcTotalTimeoutMs defaultProbeConfig `shouldBe` Nothing
