{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.N2C.Reconnect
Description : Reconnect supervisor over Control.Retry
License     : Apache-2.0

Wraps a single chain-sync run in an indefinitely-retrying
supervisor on top of @Control.Retry@. Per
@research.md § D2@: backoff is full-jitter exponential
capped at 'rpMaxMs', delivered by 'fullJitterBackoff' +
'capDelay'. The retry decision is made via
'recoveringDynamic' so we can return @DontRetry@ on async
exceptions (clean shutdown) and @ConsultPolicy@ on
synchronous failures.

Before the first chain-sync attempt (and after the outer
'forever' loop restarts, if ever) the supervisor calls
'Probe.waitForNodeReady' so we don't attach chain-sync
against a relay whose ChainDB hasn't finished loading.
Subsequent reconnect retries within the same
'recoveringDynamic' call proceed directly to
'innerAttempt' without re-probing: the relay's socket is
already confirmed reachable and its ChainDB is assumed
stable; a fast failure + exponential back-off is
sufficient to gate reconnects against a transiently
unavailable relay.
-}
module Cardano.Node.Client.N2C.Reconnect (
    -- * Policy
    ReconnectPolicy (..),
    defaultReconnectPolicy,

    -- * Upstream status surface
    UpstreamStatus (..),
    DisconnectInfo (..),

    -- * Supervisor
    runReconnectLoop,
) where

import Cardano.Node.Client.N2C.Probe (
    ProbeConfig,
    msToMicros,
    waitForNodeReady,
 )
import Cardano.Node.Client.N2C.Trace (
    N2CEvent (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo)
import Control.Exception qualified as E
import Control.Monad (forever, when)
import Control.Monad.Catch (Handler (..))
import Control.Retry (
    RetryAction (..),
    RetryStatus (..),
    capDelay,
    fullJitterBackoff,
    recoveringDynamic,
 )
import Control.Tracer (Tracer, traceWith)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Ouroboros.Network.Magic (NetworkMagic)

{- | Reconnect supervisor configuration. Constructed once
at daemon startup from CLI flags or via
'defaultReconnectPolicy'.

Invariants (caller must respect): @rpInitialMs ≤ rpMaxMs@
and @rpResetThresholdMs > 0@.
-}
data ReconnectPolicy = ReconnectPolicy
    { rpInitialMs :: !Word64
    -- ^ Base of the full-jitter exponential backoff (ms).
    , rpMaxMs :: !Word64
    -- ^ Cap of the full-jitter backoff window (ms).
    , rpResetThresholdMs :: !Word64
    -- ^ Minimum chain-sync run duration after which the
    -- supervisor's 'RetryStatus' resets to its initial
    -- state.
    }
    deriving stock (Show, Eq)

{- | Defaults from the issue body
(<https://github.com/lambdasistemi/cardano-node-clients/issues/97>):
1 s base, 30 s cap, 30 s healthy-run threshold.
-}
defaultReconnectPolicy :: ReconnectPolicy
defaultReconnectPolicy =
    ReconnectPolicy
        { rpInitialMs = 1_000
        , rpMaxMs = 30_000
        , rpResetThresholdMs = 30_000
        }

{- | Whether the indexer's upstream chain-sync session is
live. Consumed by 'Cardano.Node.Client.UTxOIndexer.Server'
to surface a structured @upstream@ field on the @ready@
response.
-}
data UpstreamStatus
    = UpstreamConnected
    | UpstreamDisconnected !DisconnectInfo
    deriving stock (Show, Eq)

{- | Carried inside 'UpstreamDisconnected'. Encodes the
operator-visible context for the in-progress reconnect.
-}
data DisconnectInfo = DisconnectInfo
    { diReason :: !Text
    -- ^ Short, human-readable reason text.
    , diAttempt :: !Int
    -- ^ 1-based counter of consecutive failed attempts.
    , diSinceMs :: !Word64
    -- ^ Cumulative backoff delay (ms) accumulated by the
    -- retry policy up to this attempt. This tracks the
    -- time the supervisor has been sleeping between
    -- reconnect attempts, not real elapsed wall time
    -- (which also includes probe and connect durations).
    }
    deriving stock (Show, Eq)

{- | Wrap a single chain-sync run in an indefinitely-
retrying supervisor.

Per outer iteration:

1. Call 'waitForNodeReady' (the probe) so we don't attach
   chain-sync against a relay whose ChainDB is still
   loading on first connect. Async exceptions propagate
   immediately.
2. Run the inner @action@ inside 'recoveringDynamic',
   which retries on synchronous failures with
   @capDelay rpMaxMs (fullJitterBackoff rpInitialMs)@.
   Each retry goes directly back to 'innerAttempt' without
   re-probing: the relay is assumed stable after the
   initial probe; fast-fail + backoff is the reconnect
   gate.
3. On retry, the handler emits 'IndexerDisconnected' and
   'IndexerReconnecting' (with the @retry@'s iteration
   counter) and updates the status sink to
   'UpstreamDisconnected'.
4. When a chain-sync run lasts ≥ 'rpResetThresholdMs'
   after at least one failure, emit 'IndexerReconnected'
   with the indexer's currently processed slot and the
   total time spent disconnected.

Async exceptions ('AsyncCancelled', termination signals)
propagate immediately so the daemon can shut down cleanly.
-}
runReconnectLoop ::
    Tracer IO N2CEvent ->
    ReconnectPolicy ->
    ProbeConfig ->
    NetworkMagic ->
    -- | Path to the upstream node Unix socket.
    FilePath ->
    -- | Status sink — invoked on every state transition.
    (UpstreamStatus -> IO ()) ->
    -- | Indexer's currently processed slot, for the
    -- 'IndexerReconnected' event.
    IO (Maybe SlotNo) ->
    -- | One chain-sync run.
    IO (Either E.SomeException ()) ->
    IO Void
runReconnectLoop
    tracer
    pol
    probeCfg
    magic
    socketPath
    setStatus
    getProcessedSlot
    chainAction = forever $ do
        waitForNodeReady tracer probeCfg magic socketPath
        recoveringDynamic
            policy
            [retryHandler]
            (innerAttempt . rsIterNumber)
      where
        policy =
            capDelay
                (msToMicros (rpMaxMs pol))
                (fullJitterBackoff (msToMicros (rpInitialMs pol)))

        -- One chain-sync attempt. iterNum = number of retries so
        -- far (0 on first try). On entry we set Connected (so the
        -- ready response advertises connected immediately when
        -- the probe has just succeeded). On a healthy run after
        -- at least one failure we emit IndexerReconnected.
        innerAttempt :: Int -> IO ()
        innerAttempt iterNum = do
            setStatus UpstreamConnected
            tStart <- getMonotonicTimeNSec
            -- Wrap with @try@ so synchronous exceptions thrown
            -- by the inner action are caught here (they'd
            -- otherwise escape 'recoveringDynamic''s handler
            -- on the way out). Async exceptions are re-thrown.
            r <- E.try chainAction
            tEnd <- getMonotonicTimeNSec
            rethrowAsync r
            let runMs = (tEnd - tStart) `div` 1_000_000
                healthy = runMs >= rpResetThresholdMs pol
            when (iterNum > 0 && healthy) $ do
                procSlot <- getProcessedSlot
                traceWith
                    tracer
                    (IndexerReconnected procSlot runMs)
            -- Either a clean Right (Right ()) (rare —
            -- chain-sync usually blocks forever), a captured
            -- Right (Left e) from runChainSyncN2C's own catch,
            -- or a Left e from an exception that escaped
            -- runChainSyncN2C entirely. All three are treated
            -- as "needs retry": throw so the recovering
            -- handler picks it up.
            case r of
                Right (Right ()) ->
                    E.throwIO . userError $
                        "chain-sync returned cleanly"
                Right (Left e) -> E.throwIO e
                Left e -> E.throwIO e

        retryHandler ::
            RetryStatus -> Handler IO RetryAction
        retryHandler rs = Handler $ \(e :: E.SomeException) ->
            case E.fromException e :: Maybe E.SomeAsyncException of
                Just _ -> pure DontRetry
                Nothing -> do
                    let reason = shortenException e
                        attempt = rsIterNumber rs + 1
                        elapsedMs =
                            fromIntegral
                                (rsCumulativeDelay rs `div` 1_000)
                    traceWith tracer (IndexerDisconnected reason)
                    setStatus
                        ( UpstreamDisconnected
                            ( DisconnectInfo
                                reason
                                attempt
                                elapsedMs
                            )
                        )
                    -- The next attempt will be made after
                    -- the policy's delay; emit Reconnecting
                    -- here with the about-to-be-made
                    -- attempt counter and the elapsed
                    -- cumulative delay so far.
                    traceWith
                        tracer
                        (IndexerReconnecting attempt elapsedMs)
                    pure ConsultPolicy

-- | Re-throw asynchronous exceptions so cancellation propagates.
rethrowAsync ::
    Either E.SomeException (Either E.SomeException ()) -> IO ()
rethrowAsync result = case result of
    Left e | isAsync e -> E.throwIO e
    Right (Left e) | isAsync e -> E.throwIO e
    _ -> pure ()

isAsync :: E.SomeException -> Bool
isAsync e =
    case E.fromException e :: Maybe E.SomeAsyncException of
        Just _ -> True
        Nothing -> False

{- | Truncate the exception's display form to ~80 chars so
log lines stay scannable.
-}
shortenException :: E.SomeException -> Text
shortenException = Text.pack . take 80 . E.displayException
