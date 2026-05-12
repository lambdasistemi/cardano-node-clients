{- |
Module      : Cardano.Node.Client.Validity
Description : Horizon-aware upper-bound slot helper.
License     : Apache-2.0

Computes the longest plutus-translatable @invalid-hereafter@ slot a caller can
use right now, given the node's hard-fork 'Interpreter' and the chain tip.

The chain horizon is the latest slot whose POSIX time the node can translate
without speculating about a future hard fork. Asking the node to evaluate a
Plutus script with an upper bound past the horizon fails with
@TimeTranslationPastHorizon@; this module avoids that by binary-searching the
translatable range using the public 'interpretQuery' API.

The 'Summary' wrapped by 'Interpreter' is documented internal in consensus;
we deliberately do not extract it via 'Codec.Serialise' round-trip or
'Unsafe.Coerce'.
-}
module Cardano.Node.Client.Validity (
    -- * Choice
    ValidityChoice (..),

    -- * Error
    HorizonError (..),

    -- * Pure selection
    selectUpperBound,

    -- * Constants (exported for tests)
    oneYearSlots,
) where

import Data.Either (isRight)
import Data.Word (Word16, Word64)

import Cardano.Slotting.Slot (SlotNo (..))

import Ouroboros.Consensus.HardFork.History.Qry (
    Interpreter,
    interpretQuery,
    slotToWallclock,
 )

{- | How the caller wants the upper-bound slot computed.

* 'AutoLongest' — pick the largest translatable slot.
* 'MaxHours' — pick @min(tip + N*3600, horizon)@. Useful when an internal
  policy caps signing windows below the chain horizon.
* 'ExactlyHours' — require @tip + N*3600@ to be inside the horizon; fail with
  'HorizonError' otherwise.
-}
data ValidityChoice
    = AutoLongest
    | MaxHours !Word16
    | ExactlyHours !Word16
    deriving stock (Eq, Show)

{- | Returned when 'ExactlyHours' overshoots the chain horizon.

Carries enough fact to render a diagnostic of the form
@"asked for N h ending at slot R, but horizon is H (tip T)"@.
-}
data HorizonError = HorizonError
    { heRequestedSlot :: !SlotNo
    , heHorizonSlot :: !SlotNo
    , heTipSlot :: !SlotNo
    , heRequestedHours :: !Word16
    }
    deriving stock (Eq, Show)

{- | Compute an @invalid-hereafter@ slot from the current 'Interpreter', tip,
and choice.

For 'AutoLongest', returns the largest slot the interpreter currently
translates. For an unbounded last era (testnets / hand-crafted summaries),
returns @tip + 'oneYearSlots'@ — the caller-visible search ceiling.
-}
selectUpperBound ::
    Interpreter xs ->
    -- | Current chain tip.
    SlotNo ->
    ValidityChoice ->
    Either HorizonError SlotNo
selectUpperBound interp tip choice =
    let horizon = findHorizonSlot interp tip
     in case choice of
            AutoLongest ->
                Right horizon
            MaxHours h ->
                Right (min (tipPlusHours tip h) horizon)
            ExactlyHours h ->
                let requested = tipPlusHours tip h
                 in if requested <= horizon
                        then Right requested
                        else
                            Left
                                HorizonError
                                    { heRequestedSlot = requested
                                    , heHorizonSlot = horizon
                                    , heTipSlot = tip
                                    , heRequestedHours = h
                                    }

{- | Largest slot the interpreter can translate, capped at @tip + oneYearSlots@.

Binary search using @slotToWallclock@ as the in-horizon predicate. The
search ceiling is a year of slots past the tip; any caller that needs more
than a year of validity is well beyond the chain's safe-zone semantics.
-}
findHorizonSlot :: Interpreter xs -> SlotNo -> SlotNo
findHorizonSlot interp tip
    | inHorizon ceilSlot = ceilSlot
    | otherwise = bsearch tip ceilSlot
  where
    ceilSlot = SlotNo (unSlotNo tip + oneYearSlots)

    inHorizon :: SlotNo -> Bool
    inHorizon s = isRight (interpretQuery interp (slotToWallclock s))

    -- INVARIANT: inHorizon lo && not (inHorizon hi)
    bsearch :: SlotNo -> SlotNo -> SlotNo
    bsearch lo hi
        | unSlotNo lo + 1 >= unSlotNo hi = lo
        | otherwise =
            let mid = SlotNo ((unSlotNo lo + unSlotNo hi) `div` 2)
             in if inHorizon mid
                    then bsearch mid hi
                    else bsearch lo mid

tipPlusHours :: SlotNo -> Word16 -> SlotNo
tipPlusHours (SlotNo t) h = SlotNo (t + fromIntegral h * 3_600)

{- | Outer search ceiling for the binary search, in slots (= 1-second slots ×
one year). Exposed so the test for the unbounded-era case can assert the
exact returned slot.
-}
oneYearSlots :: Word64
oneYearSlots = 365 * 24 * 3_600
