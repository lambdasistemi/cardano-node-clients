{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}

module Cardano.Node.Client.ValiditySpec (spec) where

import Data.SOP.NonEmpty (NonEmpty (..))
import Data.Word (Word64)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
 )

import Cardano.Slotting.Slot (EpochNo (..), EpochSize (..), SlotNo (..))
import Cardano.Slotting.Time (
    RelativeTime (..),
    slotLengthFromSec,
 )

import Ouroboros.Consensus.Block.Abstract (GenesisWindow (..))
import Ouroboros.Consensus.HardFork.History.EraParams (
    EraParams (..),
    SafeZone (..),
    pattern NoPerasEnabled,
 )
import Ouroboros.Consensus.HardFork.History.Qry (mkInterpreter)
import Ouroboros.Consensus.HardFork.History.Summary (
    Bound (..),
    EraEnd (..),
    EraSummary (..),
    Summary (..),
 )

import Cardano.Node.Client.Validity (
    HorizonError (..),
    ValidityChoice (..),
    oneYearSlots,
    selectUpperBound,
 )

-- A single-era phantom era list keeps Interpreter generic-free in tests.
type TestEras = '[()]

-- 1-second slots; mainnet-shaped 432_000-slot epoch and 36-hour safe zone.
conwayShapedParams :: EraParams
conwayShapedParams =
    EraParams
        { eraEpochSize = EpochSize 432_000
        , eraSlotLength = slotLengthFromSec 1
        , eraSafeZone = StandardSafeZone 129_600
        , eraGenesisWin = GenesisWindow 129_600
        , eraPerasRoundLength = NoPerasEnabled
        }

-- Bound at slot @s@ with 1-second slot length (so wallclock time = s seconds).
mkBound :: Word64 -> Bound
mkBound s =
    Bound
        { boundTime = RelativeTime (fromIntegral s)
        , boundSlot = SlotNo s
        , boundEpoch = EpochNo (s `div` 432_000)
        , boundPerasRound = NoPerasEnabled
        }

bounded :: Word64 -> Word64 -> EraSummary
bounded s0 s1 =
    EraSummary
        { eraStart = mkBound s0
        , eraEnd = EraEnd (mkBound s1)
        , eraParams = conwayShapedParams
        }

unbounded :: Word64 -> EraSummary
unbounded s0 =
    EraSummary
        { eraStart = mkBound s0
        , eraEnd = EraUnbounded
        , eraParams = conwayShapedParams{eraSafeZone = UnsafeIndefiniteSafeZone}
        }

-- Last era ends at slot 1_000_000 (exclusive).
midEpochSummary :: Summary TestEras
midEpochSummary = Summary (NonEmptyOne (bounded 0 1_000_000))

-- Last era is unbounded.
unboundedSummary :: Summary TestEras
unboundedSummary = Summary (NonEmptyOne (unbounded 0))

spec :: Spec
spec = describe "Cardano.Node.Client.Validity.selectUpperBound" $ do
    let midEpochInterp = mkInterpreter midEpochSummary
        unboundedInterp = mkInterpreter unboundedSummary

        midTip = SlotNo 500_000
        lateTip = SlotNo 990_000
        unboundedTip = SlotNo 1_000

        -- bounded era ends at slot 1_000_000 (exclusive)
        -- ⇒ last translatable slot is 999_999.
        eraHorizon = SlotNo 999_999

    describe "AutoLongest" $ do
        it "mid-epoch: returns the era horizon" $
            selectUpperBound midEpochInterp midTip AutoLongest
                `shouldBe` Right eraHorizon

        it "late-in-era: still returns the era horizon" $
            selectUpperBound midEpochInterp lateTip AutoLongest
                `shouldBe` Right eraHorizon

        it "unbounded era: returns the search ceiling (tip + 1 year)" $
            selectUpperBound unboundedInterp unboundedTip AutoLongest
                `shouldBe` Right (SlotNo (unSlotNo unboundedTip + oneYearSlots))

    describe "MaxHours" $ do
        it "mid-epoch with hours inside horizon: returns tip + hours" $
            -- 4h = 14_400s; tip+4h = 514_400 < eraHorizon 999_999.
            selectUpperBound midEpochInterp midTip (MaxHours 4)
                `shouldBe` Right (SlotNo 514_400)

        it "late-in-era with hours exceeding horizon: clamps to horizon" $
            -- lateTip + 24h = 1_076_400 > eraHorizon ⇒ clamp to horizon.
            selectUpperBound midEpochInterp lateTip (MaxHours 24)
                `shouldBe` Right eraHorizon

        it "unbounded era: respects hours cap" $
            selectUpperBound unboundedInterp unboundedTip (MaxHours 1)
                `shouldBe` Right (SlotNo 4_600)

    describe "ExactlyHours" $ do
        it "mid-epoch with hours inside horizon: returns tip + hours" $
            selectUpperBound midEpochInterp midTip (ExactlyHours 4)
                `shouldBe` Right (SlotNo 514_400)

        it "late-in-era with hours exceeding horizon: returns HorizonError" $
            selectUpperBound midEpochInterp lateTip (ExactlyHours 24)
                `shouldBe` Left
                    HorizonError
                        { heRequestedSlot = SlotNo 1_076_400
                        , heHorizonSlot = eraHorizon
                        , heTipSlot = lateTip
                        , heRequestedHours = 24
                        }

        it "unbounded era with large hours: returns tip + hours" $
            selectUpperBound unboundedInterp unboundedTip (ExactlyHours 100)
                `shouldBe` Right (SlotNo (1_000 + 100 * 3_600))
