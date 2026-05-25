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
    applyUpstreamStatus,
) where

import Cardano.Node.Client.N2C.Probe (ProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy,
    UpstreamStatus (..),
 )
import Cardano.Node.Client.N2C.Trace (
    N2CEvent (..),
    StopReason (..),
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    Readiness (..),
    withChainSyncFollower,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    withInMemoryIndexer,
    withRocksDBIndexer,
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
import Control.Tracer (Tracer, traceWith)
import Data.Word (Word32, Word64)
import Ouroboros.Network.Magic (NetworkMagic (..))

{- | Daemon runtime configuration. Plain Haskell record;
the CLI-parsing in @Main@ produces this.
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
                    runServer (dcListenSocket cfg) idx getReady
    onStart =
        traceWith
            tracer
            (IndexerStarted (dcListenSocket cfg) (dcDbPath cfg))
    onStop r = traceWith tracer (IndexerStopped r)
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) = withRocksDBIndexer path

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
        , csReadyThresholdSlots = dcReadyThresholdSlots cfg
        , csSecurityParamK = dcSecurityParamK cfg
        , csReconnectPolicy = dcReconnectPolicy cfg
        , csProbeConfig = dcProbeConfig cfg
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
        { rsReady = case (rUpstream r, behind) of
            (UpstreamConnected, Just b) ->
                b <= dcReadyThresholdSlots cfg
            _ -> False
        , rsTipSlot = rTipSlot r
        , rsProcessedSlot = rProcessedSlot r
        , rsSlotsBehind = behind
        , rsUpstream = rUpstream r
        }
  where
    behind = case (rProcessedSlot r, rTipSlot r) of
        (Just (SlotNo p), Just (SlotNo t)) ->
            Just (if t > p then t - p else 0)
        _ -> Nothing

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
