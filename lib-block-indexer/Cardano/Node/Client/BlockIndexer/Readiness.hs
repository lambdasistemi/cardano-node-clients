{- |
Module      : Cardano.Node.Client.BlockIndexer.Readiness
Description : Generic readiness and lag helpers for block indexers
License     : Apache-2.0

Reusable readiness state for block-indexer consumers.

The record is generic in both slot and upstream-status
types so this library does not depend on any concrete
node-client reconnect module or downstream indexer. UTxO
daemon wire types adapt to this generic shape, but this
module intentionally does not import the UTxO indexer.
-}
module Cardano.Node.Client.BlockIndexer.Readiness (
    -- * Snapshot
    Readiness (..),
    initialReadiness,
    applyUpstreamToReadiness,

    -- * Lag calculation
    slotLag,
    readinessSlotLag,

    -- * Readiness decisions
    readyFromLag,
    readyWithinLag,
)
where

import Data.Time.Clock (UTCTime)
import Data.Word (Word64)

{- | Live readiness snapshot shared by indexer runners.

The slot fields are intentionally optional: they stay
'Nothing' until the first roll-forward supplies both the
processed slot and the observed tip slot. Consumers decide
what their upstream status type means by passing a
predicate to 'readyWithinLag'.
-}
data Readiness slot upstream = Readiness
    { rProcessedSlot :: !(Maybe slot)
    -- ^ Highest slot the indexer has processed.
    , rTipSlot :: !(Maybe slot)
    -- ^ Latest tip slot observed from the upstream node.
    , rUpstream :: !upstream
    -- ^ Caller-defined upstream status value.
    , rUpdatedAt :: !UTCTime
    -- ^ Wall-clock time of the last readiness write.
    }
    deriving stock (Eq, Show)

{- | Initial readiness value: no slots observed yet and
the caller-supplied upstream status.
-}
initialReadiness :: upstream -> UTCTime -> Readiness slot upstream
initialReadiness upstream now =
    Readiness
        { rProcessedSlot = Nothing
        , rTipSlot = Nothing
        , rUpstream = upstream
        , rUpdatedAt = now
        }

{- | Apply an upstream status transition while preserving
processed and tip slots.
-}
applyUpstreamToReadiness ::
    upstream ->
    UTCTime ->
    Readiness slot upstream ->
    Readiness slot upstream
applyUpstreamToReadiness upstream now r =
    r{rUpstream = upstream, rUpdatedAt = now}

{- | Derive slot lag from processed and tip slots.

Returns 'Nothing' until both slots are known. When the
processed slot is ahead of the tip slot, lag is clamped
to zero; this preserves readiness through benign races
between local processing and upstream tip observations.
-}
slotLag :: (slot -> Word64) -> Maybe slot -> Maybe slot -> Maybe Word64
slotLag toWord64 processed tip = do
    processedSlot <- toWord64 <$> processed
    tipSlot <- toWord64 <$> tip
    pure $
        if tipSlot > processedSlot
            then tipSlot - processedSlot
            else 0

-- | Derive slot lag from a 'Readiness' snapshot.
readinessSlotLag ::
    (slot -> Word64) ->
    Readiness slot upstream ->
    Maybe Word64
readinessSlotLag toWord64 r =
    slotLag toWord64 (rProcessedSlot r) (rTipSlot r)

{- | Decide whether a readiness snapshot is ready under a
slot-lag threshold, optional lag, and caller-supplied
upstream-connected predicate.
-}
readyFromLag ::
    (upstream -> Bool) ->
    Word64 ->
    upstream ->
    Maybe Word64 ->
    Bool
readyFromLag upstreamConnected threshold upstream lag =
    case lag of
        Just slotsBehind
            | upstreamConnected upstream ->
                slotsBehind <= threshold
        _ -> False

{- | Decide whether a readiness snapshot is ready under a
slot-lag threshold and caller-supplied upstream-connected
predicate.
-}
readyWithinLag ::
    (slot -> Word64) ->
    (upstream -> Bool) ->
    Word64 ->
    Readiness slot upstream ->
    Bool
readyWithinLag toWord64 upstreamConnected threshold r =
    readyFromLag
        upstreamConnected
        threshold
        (rUpstream r)
        (readinessSlotLag toWord64 r)
