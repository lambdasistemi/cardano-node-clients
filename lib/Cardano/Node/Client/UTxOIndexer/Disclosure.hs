{- |
Module      : Cardano.Node.Client.UTxOIndexer.Disclosure
Description : Network, coverage and freshness of an asset answer
License     : Apache-2.0

What a successful @utxos_with_asset@ answer states about the index
that produced it, beside its point and holders:

* the network magic of the follower serving the store;
* the coverage of that follower: where it started (origin or a
  concrete point) and whether it indexes every address or a filtered
  set;
* the upstream freshness: @synced@, @catching_up@, @disconnected@ or
  @stale@, the last observed tip slot, how far the answer's own point
  is behind it, and the seconds since the follower last made
  progress;
* the limits: every reason the answer may differ from the chain-wide
  answer at its point. An empty list is the only form that claims the
  chain's answer.

The 'Disclosure' is fixed for the life of the serving process; the
'Freshness' is derived per answer from one readiness sample and one
clock sample taken after the answer's storage read.
-}
module Cardano.Node.Client.UTxOIndexer.Disclosure (
    -- * Fixed per serving process
    Disclosure (..),
    Coverage (..),
    CoverageStart (..),
    AddressCoverage (..),

    -- * Derived per answer
    Freshness (..),
    FreshnessStatus (..),
    Limit (..),
    assessFreshness,
    answerLimits,

    -- * Readiness sample
    ReadyStatus (..),
) where

import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    BlockHash,
    SlotNo (..),
 )
import Data.Aeson (
    ToJSON (..),
    object,
    (.=),
 )
import Data.Text (Text)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Word (Word32, Word64)

-- | Where the serving follower's history starts.
data CoverageStart
    = -- | From the genesis of the chain.
      FromOrigin
    | -- | From this block: nothing before it is indexed.
      FromPoint !SlotNo !BlockHash
    deriving stock (Eq, Show)

-- | Which addresses the serving follower indexes.
data AddressCoverage
    = AllAddresses
    | -- | Only an address set; outputs elsewhere are not indexed.
      FilteredAddresses
    deriving stock (Eq, Show)

-- | The coverage of the serving follower.
data Coverage = Coverage
    { covStart :: !CoverageStart
    , covAddresses :: !AddressCoverage
    }
    deriving stock (Eq, Show)

-- | What the serving process states on every asset answer.
data Disclosure = Disclosure
    { dsNetworkMagic :: !Word32
    -- ^ Magic the serving follower connects with.
    , dsCoverage :: !Coverage
    , dsReadyThresholdSlots :: !Word64
    -- ^ Lag beyond which the answer is catching up, as @ready@.
    , dsStaleAfterSeconds :: !Word64
    -- ^ Seconds without follower progress beyond which a connected
    -- upstream is stale.
    }
    deriving stock (Eq, Show)

-- | The upstream freshness of an answer.
data FreshnessStatus
    = Synced
    | CatchingUp
    | Disconnected
    | Stale
    deriving stock (Eq, Show)

-- | The freshness of one answer, measured against its own point.
data Freshness = Freshness
    { frStatus :: !FreshnessStatus
    , frTipSlot :: !(Maybe SlotNo)
    -- ^ Last observed upstream tip slot, if any.
    , frSlotsBehind :: !(Maybe Word64)
    -- ^ Tip slot minus the answer's point slot, clamped at zero;
    -- 'Nothing' when the tip is unknown.
    , frSecondsSinceProgress :: !Word64
    -- ^ Whole seconds since the follower's last progress.
    }
    deriving stock (Eq, Show)

-- | A reason the answer may differ from the chain-wide answer.
data Limit
    = AddressFilterLimit
    | PartialHistoryLimit
    | CatchingUpLimit
    | DisconnectedLimit
    | StaleLimit
    deriving stock (Eq, Ord, Show, Enum, Bounded)

{- | Sync-readiness snapshot used for the @ready@
endpoint. Mirrors @cardano-utxo-csmt@'s @ReadyResponse@
field shape (@ready@/@tipSlot@/@processedSlot@/
@slotsBehind@) so consumers wired against either
daemon get the same JSON.

The 'rsUpstream' field surfaces the reconnect supervisor's
view of the upstream chain-sync session. Invariant:
'rsUpstream' = 'UpstreamDisconnected' implies
'rsReady' is 'False'. The 'ToJSON' encoder enforces this
defensively on the wire — 'rsReady' is set to 'False'
whenever 'rsUpstream' is in the disconnected state, even
if the producer's 'TVar' lags. Encoding stays
backwards-compatible: the @upstream@ field is omitted
entirely when the supervisor reports
'UpstreamConnected'. See
@specs\/035-indexer-n2c-reconnect\/contracts\/control-wire.md@.

'rsLastProgress' is the time of the follower's last
progress (a roll-forward applied or an upstream status
change); it is not on the wire of @ready@.
-}
data ReadyStatus = ReadyStatus
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe SlotNo)
    , rsProcessedSlot :: !(Maybe SlotNo)
    , rsSlotsBehind :: !(Maybe Word64)
    , rsUpstream :: !UpstreamStatus
    , rsLastProgress :: !UTCTime
    }
    deriving stock (Eq, Show)

instance ToJSON ReadyStatus where
    toJSON
        ReadyStatus
            { rsReady
            , rsTipSlot
            , rsProcessedSlot
            , rsSlotsBehind
            , rsUpstream
            } =
            object (baseFields <> upstreamField)
          where
            -- Defensively force ready=False whenever the
            -- supervisor reports a disconnected upstream.
            ready = case rsUpstream of
                UpstreamConnected -> rsReady
                UpstreamDisconnected _ -> False
            unSlotNo (SlotNo s) = s
            baseFields =
                [ "ready" .= ready
                , "tipSlot" .= fmap unSlotNo rsTipSlot
                , "processedSlot" .= fmap unSlotNo rsProcessedSlot
                , "slotsBehind" .= rsSlotsBehind
                ]
            upstreamField = case rsUpstream of
                UpstreamConnected -> []
                UpstreamDisconnected di ->
                    [ "upstream"
                        .= object
                            [ "status" .= ("disconnected" :: Text)
                            , "reason" .= diReason di
                            , "attempt" .= diAttempt di
                            , "elapsedMs" .= diSinceMs di
                            ]
                    ]

{- | The freshness of an answer whose snapshot is at @point@,
from one readiness sample and one clock sample taken after
the snapshot was read.

Precedence: @disconnected@ (the supervisor reports the
upstream down), then @stale@ (connected, and the whole
seconds since the last progress exceed the stale bound),
then @catching_up@ (tip unknown, or the point more than the
ready threshold behind it), then @synced@.

The lag is measured from @point@, never from the readiness
sample's processed slot: an answer states how far /it/ is
behind the tip.
-}
assessFreshness ::
    Disclosure ->
    UTCTime ->
    ReadyStatus ->
    SlotNo ->
    Freshness
assessFreshness disclosure now ready (SlotNo point) =
    Freshness
        { frStatus = status
        , frTipSlot = rsTipSlot ready
        , frSlotsBehind = behind
        , frSecondsSinceProgress = seconds
        }
  where
    behind = lagFrom <$> rsTipSlot ready
    lagFrom (SlotNo tip)
        | tip > point = tip - point
        | otherwise = 0
    age = diffUTCTime now (rsLastProgress ready)
    seconds
        | age <= 0 = 0
        | otherwise = floor age
    status = case rsUpstream ready of
        UpstreamDisconnected _ -> Disconnected
        UpstreamConnected
            | seconds > dsStaleAfterSeconds disclosure -> Stale
            | otherwise -> case behind of
                Nothing -> CatchingUp
                Just lag
                    | lag > dsReadyThresholdSlots disclosure -> CatchingUp
                    | otherwise -> Synced

{- | Every reason an answer may differ from the chain-wide
answer at its point, in wire order: the address filter,
partial history, then the freshness status unless synced.
Empty only for full coverage from origin and a synced
answer.
-}
answerLimits :: Coverage -> Freshness -> [Limit]
answerLimits Coverage{covStart, covAddresses} Freshness{frStatus} =
    [AddressFilterLimit | covAddresses == FilteredAddresses]
        <> [PartialHistoryLimit | covStart /= FromOrigin]
        <> case frStatus of
            Synced -> []
            CatchingUp -> [CatchingUpLimit]
            Disconnected -> [DisconnectedLimit]
            Stale -> [StaleLimit]
