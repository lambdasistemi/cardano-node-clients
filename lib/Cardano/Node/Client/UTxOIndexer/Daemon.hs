{- |
Module      : Cardano.Node.Client.UTxOIndexer.Daemon
Description : Daemon entrypoint — wires Follower + NDJSON server
License     : Apache-2.0

Composes the bundled @utxo-indexer@ binary by gluing together:

* an 'IndexerHandle' it opens locally (RocksDB or in-memory),
* the chain-sync follower from
  "Cardano.Node.Client.UTxOIndexer.Follower" (extracted in
  cardano-node-clients#156 so downstream consumers like
  @amaru-treasury-tx-api@ can run the follower against a
  caller-owned handle without the NDJSON server),
* the NDJSON Unix-socket server from
  "Cardano.Node.Client.UTxOIndexer.Server".

A 'TVar' 'ReadyStatus' is derived from the follower's
'Readiness' on each NDJSON @ready@ request so the wire
format (including @upstream.reason@ on disconnect) is
preserved across the refactor.
-}
module Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
    parseDaemonArgs,
    applyUpstreamStatus,
) where

import Cardano.Node.Client.BlockIndexer.Readiness qualified as Readiness
import Cardano.Node.Client.N2C.Probe (
    ProbeConfig (..),
    defaultProbeConfig,
 )
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy (..),
    UpstreamStatus (..),
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.N2C.Trace (
    N2CEvent (..),
    StopReason (..),
 )
import Cardano.Node.Client.UTxOIndexer.Disclosure (
    Disclosure (..),
    storeCoverage,
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    InterestSet (..),
    Readiness (..),
    withChainSyncFollower,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    OpenOptions (..),
    StoreCoverage,
    defaultOpenOptions,
    liveUtxoHandler,
    withInMemoryIndexer,
    withRocksDBIndexerWith,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    SlotNo (..),
 )
import Control.Concurrent.STM (atomically)
import Control.Exception (onException)
import Control.Tracer (Tracer, nullTracer, traceWith)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Word (Word32, Word64)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Text.Read (readMaybe)

{- | Daemon runtime configuration. Plain Haskell record;
'parseDaemonArgs' produces it from the command line.
-}
data DaemonConfig = DaemonConfig
    { dcRelaySocket :: FilePath
    , dcListenSocket :: FilePath
    , dcNetworkMagic :: Word32
    , dcByronEpochSlots :: Word64
    , dcReadyThresholdSlots :: Word64
    , dcSecurityParamK :: Int
    -- ^ Cardano security parameter @k@ — the
    -- rollback-log entry count is capped at this many,
    -- and older entries are dropped after each apply.
    , dcDbPath :: Maybe FilePath
    -- ^ When 'Just', open the indexer against a RocksDB
    -- database at this path; state survives process
    -- restart. When 'Nothing', use the volatile
    -- in-memory backend (intended for tests).
    , dcReconnectPolicy :: !ReconnectPolicy
    -- ^ Backoff policy for the in-process reconnect
    -- supervisor. Defaults via 'defaultReconnectPolicy'.
    , dcProbeConfig :: !ProbeConfig
    -- ^ Configuration for the LSQ tip probe that gates
    -- each reconnect attempt. Defaults via
    -- 'defaultProbeConfig' — chain-replay-tolerant
    -- (unbounded total timeout).
    , dcStaleAfterSeconds :: !Word64
    -- ^ Seconds without follower progress beyond which a
    -- connected upstream makes asset answers @stale@.
    , dcRebuildAssetIndex :: !Bool
    -- ^ Request the asset-index upgrade of the RocksDB
    -- store at 'dcDbPath' (CLI @--rebuild-asset-index@).
    -- A store without a complete asset index — one
    -- created before the index existed, or one that met
    -- an unreadable output — rebuilds it online from its
    -- own live outputs. A store with a complete index, a
    -- new store and the in-memory backend ignore it.
    }
    deriving stock (Show)

{- | Open the indexer (RocksDB if @dcDbPath@ is set,
in-memory otherwise), start the NDJSON server and the
chain-sync follower, and block.

The follower runs under
'Cardano.Node.Client.UTxOIndexer.Follower.withChainSyncFollower',
which wraps the chain-sync session in a reconnect
supervisor. When the upstream relay disconnects, the
supervisor catches the exception, probes the relay via
LSQ until ready, and re-attempts chain-sync; the listen
socket and indexer state persist across the reconnect
window.

The caller-provided 'Tracer' receives an 'IndexerStarted'
on entry and an 'IndexerStopped' on exit (both clean
termination and async cancellation), plus all
reconnect-supervisor and probe events between.
-}
runDaemon :: Tracer IO N2CEvent -> DaemonConfig -> IO ()
runDaemon tracer cfg = do
    onStart
    runBody `onException` onStop StoppedAsync
    onStop StoppedNormally
  where
    runBody =
        withIndexer (dcDbPath cfg) $ \idx ->
            withChainSyncFollower
                tracer
                (toChainSyncCfg cfg)
                idx
                $ \fh -> do
                    let getReady =
                            readyStatusFrom cfg
                                <$> atomically (fhReadiness fh)
                    runServer
                        (dcListenSocket cfg)
                        idx
                        (daemonDisclosure cfg (fhStoreCoverage fh))
                        getReady
    onStart =
        traceWith
            tracer
            (IndexerStarted (dcListenSocket cfg) (dcDbPath cfg))
    onStop r = traceWith tracer (IndexerStopped r)
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) =
        withRocksDBIndexerWith
            defaultOpenOptions
                { ooRebuildAssetIndex = dcRebuildAssetIndex cfg
                }
            path

{- | Lift the daemon's flat 'DaemonConfig' into the
follower-shaped 'ChainSyncConfig'. Field names track the
'DaemonConfig' / 'ChainSyncConfig' split — see the
@Follower@ module Haddock for the per-field semantics.
-}
toChainSyncCfg :: DaemonConfig -> ChainSyncConfig
toChainSyncCfg cfg =
    ChainSyncConfig
        { csRelaySocket = dcRelaySocket cfg
        , csNetworkMagic = NetworkMagic (dcNetworkMagic cfg)
        , csByronEpochSlots = dcByronEpochSlots cfg
        , csStartPoint = Nothing
        , csReadyThresholdSlots = dcReadyThresholdSlots cfg
        , csSecurityParamK = dcSecurityParamK cfg
        , csReconnectPolicy = dcReconnectPolicy cfg
        , csProbeConfig = dcProbeConfig cfg
        , -- The bundled @utxo-indexer@ daemon indexes
          -- the full chain by default (issue #158).
          -- Downstream in-process consumers can construct
          -- a 'ChainSyncConfig' directly with
          -- 'IndexAddressSet' to bound the on-disk store.
          csInterestSet = IndexAll
        , csHandlers = liveUtxoHandler IndexAll :| []
        , csBlockTracer = nullTracer
        , csTipTracer = nullTracer
        , csHistory = Nothing
        }

{- | Derive the bundled daemon's wire-format 'ReadyStatus'
from the follower's leaner 'Readiness'.

@rsReady@ is recomputed at read time from
@rsSlotsBehind@ against 'dcReadyThresholdSlots' and the
upstream status — keeping the threshold rule in one
place (matching 'applyUpstreamStatus''s semantics
post-reconnect, which is the issue #119 regression
locked in by "DaemonSpec").
-}
readyStatusFrom :: DaemonConfig -> Readiness -> ReadyStatus
readyStatusFrom cfg r =
    ReadyStatus
        { rsReady =
            Readiness.readyFromLag
                upstreamConnected
                (dcReadyThresholdSlots cfg)
                (rUpstream r)
                behind
        , rsTipSlot = rTipSlot r
        , rsProcessedSlot = rProcessedSlot r
        , rsSlotsBehind = behind
        , rsUpstream = rUpstream r
        , rsLastProgress = rUpdatedAt r
        }
  where
    behind =
        Readiness.slotLag unSlotNo (rProcessedSlot r) (rTipSlot r)
    unSlotNo (SlotNo slot) = slot
    upstreamConnected UpstreamConnected = True
    upstreamConnected (UpstreamDisconnected _) = False

{- | Apply a supervisor status transition to a 'ReadyStatus'.

  * @'UpstreamDisconnected' _@ → keep slot fields, force
    @rsReady = False@.
  * @'UpstreamConnected'@      → keep slot fields, re-derive
    @rsReady@ from the current @rsSlotsBehind@ against
    @dcReadyThresholdSlots@. This is what makes the daemon
    flip back to @ready=true@ on reconnect to a chain that is
    already at the last seen tip — without this re-derive,
    @rsReady@ stays @False@ until the next 'rollForward'
    fires the follower's readiness update. See issue #119.

Post-refactor (#156) this pure function is no longer
called from 'runDaemon''s body — the same semantics are
performed at read time by 'readyStatusFrom'. The function
remains exported and behavior-stable so the @DaemonSpec@
regression tests continue to lock in the issue #119
guarantee.
-}
applyUpstreamStatus ::
    DaemonConfig ->
    UpstreamStatus ->
    ReadyStatus ->
    ReadyStatus
applyUpstreamStatus cfg newStatus rs =
    case newStatus of
        UpstreamConnected ->
            rs
                { rsUpstream = UpstreamConnected
                , rsReady = case rsSlotsBehind rs of
                    Just b -> b <= dcReadyThresholdSlots cfg
                    Nothing -> False
                }
        UpstreamDisconnected _ ->
            rs
                { rsUpstream = newStatus
                , rsReady = False
                }

{- | What every asset answer of this daemon states: the magic
its follower connects with, the coverage its store holds for
the follower's session, the ready threshold and the stale
bound.
-}
daemonDisclosure :: DaemonConfig -> StoreCoverage -> Disclosure
daemonDisclosure cfg coverage =
    Disclosure
        { dsNetworkMagic = dcNetworkMagic cfg
        , dsCoverage = storeCoverage coverage
        , dsReadyThresholdSlots = dcReadyThresholdSlots cfg
        , dsStaleAfterSeconds = dcStaleAfterSeconds cfg
        }

-- | Default stale bound (seconds).
defaultStaleAfterSeconds :: Word64
defaultStaleAfterSeconds = 600

-- | Default ready threshold (slots).
defaultReadyThreshold :: Word
defaultReadyThreshold = 60

{- | Default Cardano security parameter @k@ — the
rollback log is capped at this many of the most-recent
entries (per-block, not per-slot). Mainnet/preprod/
preview all use 2160; devnets typically override.
-}
defaultSecurityParamK :: Word
defaultSecurityParamK = 2160

{- | Take a flag that carries no value from the argument list:
whether it was present, and the remaining args.
-}
takeSwitch :: String -> [String] -> (Bool, [String])
takeSwitch key args = (key `elem` args, filter (/= key) args)

{- | Parse a single @--key value@ pair from the argument
list. Returns the value and the remaining args.
-}
takeFlag :: String -> [String] -> Maybe (String, [String])
takeFlag _ [] = Nothing
takeFlag key args = go [] args
  where
    go _ [] = Nothing
    go seen (k : v : rest)
        | k == key = Just (v, reverse seen ++ rest)
    go seen (x : rest) = go (x : seen) rest

{- | Parse the daemon's command-line flags into a
'DaemonConfig'. 'Left' carries the message to print
above the usage text.
-}
parseDaemonArgs :: [String] -> Either String DaemonConfig
parseDaemonArgs args0 = do
    (relay, args1) <- requireFlag "--relay-socket" args0
    (listen, args2) <- requireFlag "--listen" args1
    (magicS, args3) <- requireFlag "--network-magic" args2
    (slotsS, args4) <- requireFlag "--byron-epoch-slots" args3
    let (readyS, args5) =
            fromMaybe (show defaultReadyThreshold, args4) $
                takeFlag "--ready-threshold-slots" args4
        (kS, args6) =
            fromMaybe (show defaultSecurityParamK, args5) $
                takeFlag "--security-param-k" args5
        (mDbPath, args7) = case takeFlag "--db-path" args6 of
            Just (p, rest) -> (Just p, rest)
            Nothing -> (Nothing, args6)
        (initialMsS, args8) =
            fromMaybe
                (show (rpInitialMs defaultReconnectPolicy), args7)
                (takeFlag "--reconnect-initial-ms" args7)
        (maxMsS, args9) =
            fromMaybe
                (show (rpMaxMs defaultReconnectPolicy), args8)
                (takeFlag "--reconnect-max-ms" args8)
        (resetMsS, args10) =
            fromMaybe
                ( show (rpResetThresholdMs defaultReconnectPolicy)
                , args9
                )
                (takeFlag "--reconnect-reset-threshold-ms" args9)
        (mTotalMs, args11) = case takeFlag "--node-ready-timeout-ms" args10 of
            Just (s, rest) -> (Just s, rest)
            Nothing -> (Nothing, args10)
        (mStaleS, args12) = case takeFlag "--stale-after-seconds" args11 of
            Just (s, rest) -> (Just s, rest)
            Nothing -> (Nothing, args11)
        (rebuildAssetIndex, args13) =
            takeSwitch "--rebuild-asset-index" args12
    case args13 of
        [] -> pure ()
        extra -> Left $ "Unexpected args: " <> show extra
    magic <- requireWord "--network-magic" magicS
    slots <- requireWord "--byron-epoch-slots" slotsS
    ready <- requireWord "--ready-threshold-slots" readyS
    k <- requireWord "--security-param-k" kS
    initialMs <-
        requireWord "--reconnect-initial-ms" initialMsS
    maxMs <- requireWord "--reconnect-max-ms" maxMsS
    resetMs <-
        requireWord "--reconnect-reset-threshold-ms" resetMsS
    mTotalMsParsed <- case mTotalMs of
        Nothing -> pure Nothing
        Just s ->
            Just <$> requireWord "--node-ready-timeout-ms" s
    staleAfter <-
        maybe (Right defaultStaleAfterSeconds) requirePositive mStaleS
    let policy =
            ReconnectPolicy
                { rpInitialMs = fromIntegral (initialMs :: Word)
                , rpMaxMs = fromIntegral (maxMs :: Word)
                , rpResetThresholdMs =
                    fromIntegral (resetMs :: Word)
                }
        probe =
            defaultProbeConfig
                { pcTotalTimeoutMs =
                    fmap
                        (fromIntegral :: Word -> Word64)
                        mTotalMsParsed
                }
    pure
        DaemonConfig
            { dcRelaySocket = relay
            , dcListenSocket = listen
            , dcNetworkMagic = fromIntegral (magic :: Word)
            , dcByronEpochSlots = fromIntegral (slots :: Word)
            , dcReadyThresholdSlots = fromIntegral (ready :: Word)
            , dcSecurityParamK = fromIntegral (k :: Word)
            , dcDbPath = mDbPath
            , dcReconnectPolicy = policy
            , dcProbeConfig = probe
            , dcStaleAfterSeconds = staleAfter
            , dcRebuildAssetIndex = rebuildAssetIndex
            }
  where
    requireFlag key args =
        maybe
            (Left $ "Missing required flag: " <> key)
            Right
            (takeFlag key args)
    requireWord key s =
        maybe
            (Left $ key <> " expects a non-negative integer, got: " <> s)
            Right
            (readMaybe s)
    -- Read through Integer: reading a Word wraps negative input.
    requirePositive s = case readMaybe s :: Maybe Integer of
        Just n
            | n >= 1 && n <= toInteger (maxBound :: Word64) ->
                Right (fromInteger n)
        _ ->
            Left $
                "--stale-after-seconds expects a positive whole number of seconds, got: "
                    <> s
