{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.HorizonSpec
Description : Devnet E2E smoke for the horizon-aware validity helper.
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.HorizonSpec (spec) where

import Test.Hspec (
    Spec,
    around,
    describe,
    it,
    shouldSatisfy,
 )

import Cardano.Slotting.Slot (SlotNo (..))

import Cardano.Node.Client.E2E.Setup (withDevnet)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Validity (ValidityChoice (..))

spec :: Spec
spec =
    around withDevnet' $
        describe "Provider.queryUpperBoundSlot" $ do
            it "AutoLongest returns a slot >= 1 (devnet has a known era)" $
                \(lsq, _) -> do
                    let provider = mkN2CProvider lsq
                    result <-
                        queryUpperBoundSlot
                            provider
                            AutoLongest
                    result
                        `shouldSatisfy` isRightSlotAtLeast 1
            it "MaxHours clamps a far-future request to the devnet horizon" $
                -- Devnet eras are short; we don't know the exact horizon, so
                -- we ask for one hour (way past horizon) and assert the
                -- result is the same slot 'AutoLongest' returns. This is the
                -- contract of MaxHours: clamp, never fail.
                \(lsq, _) -> do
                    let provider = mkN2CProvider lsq
                    auto <-
                        queryUpperBoundSlot
                            provider
                            AutoLongest
                    capped <-
                        queryUpperBoundSlot
                            provider
                            (MaxHours 1)
                    capped `shouldSatisfy` (== auto)
            it "ExactlyHours past the horizon returns HorizonError" $
                -- Same setup; ExactlyHours fails fast where MaxHours clamps.
                \(lsq, _) -> do
                    let provider = mkN2CProvider lsq
                    result <-
                        queryUpperBoundSlot
                            provider
                            (ExactlyHours 1)
                    result `shouldSatisfy` isLeft
  where
    withDevnet' action = withDevnet $ curry action

    isRightSlotAtLeast :: Word -> Either e SlotNo -> Bool
    isRightSlotAtLeast n (Right (SlotNo s)) = s >= fromIntegral n
    isRightSlotAtLeast _ _ = False

    isLeft :: Either e a -> Bool
    isLeft (Left _) = True
    isLeft _ = False
