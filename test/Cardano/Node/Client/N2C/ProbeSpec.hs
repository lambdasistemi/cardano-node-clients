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
    waitForNodeReady,
 )
import Cardano.Node.Client.N2C.Trace (renderN2CEvent)
import Control.Exception (SomeException, try)
import Control.Tracer (mkTracer)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Cardano.Node.Client.N2C.Probe" $ do
    it "reports an unavailable socket as a probe failure, not chain replay" $
        withSystemTempDirectory "n2c-probe" $ \dir -> do
            events <- newIORef []
            let tracer = mkTracer $ \event ->
                    modifyIORef' events (renderN2CEvent event :)
                config = defaultProbeConfig{pcTotalTimeoutMs = Just 0}
            result <-
                try @SomeException $
                    waitForNodeReady tracer config (NetworkMagic 42) (dir </> "missing.socket")
            result `shouldSatisfy` isLeft
            observed <- readIORef events
            observed
                `shouldSatisfy` any (Text.isInfixOf (Text.pack "event=node-probe-failed"))
            observed
                `shouldSatisfy` (not . any (Text.isInfixOf (Text.pack "event=node-replaying")))
    describe "defaultProbeConfig" $ do
        it "per-attempt timeout = 5_000 ms" $
            pcAttemptTimeoutMs defaultProbeConfig `shouldBe` 5_000
        it "between-attempts backoff base = 250 ms" $
            pcRetryBaseMs defaultProbeConfig `shouldBe` 250
        it "between-attempts backoff cap = 5_000 ms" $
            pcRetryMaxMs defaultProbeConfig `shouldBe` 5_000
        it "total timeout default is unbounded (Nothing)" $
            pcTotalTimeoutMs defaultProbeConfig `shouldBe` Nothing
