{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.Probe
Description : "Is the upstream node ready?" probe over LSQ
License     : Apache-2.0

cardano-node binds its Unix socket BEFORE its ChainDB has
finished loading. A naïve reconnect against a freshly
restarted node sees a chain whose tip is below the
indexer's saved rollback points and trips the WarmBoot
@intersectNotFound@ guard. Per @research.md § D6@, the
right way to gate reconnect is to probe the node via
LocalStateQuery: open an LSQ-only connection, call
@GetChainPoint@, succeed when the response is non-Origin.

The LSQ server is not started until ChainDB has finished
loading (per
@ouroboros-consensus-diffusion/Ouroboros/Consensus/Node.hs:519,983@),
so during chain replay the @MsgAcquire VolatileTip@ simply
hangs with no protocol-level "I'm not ready" message
(@LocalStateQuery.Type:114-128@). The probe must therefore
be timeout-based — the per-attempt timeout is the cap on
how long we'll wait before logging an
'IndexerNodeReplaying' event and retrying.

The total wait is unbounded by default: chain replay on
a real testnet can take minutes or longer; we don't want
to give up. Operators set @pcTotalTimeoutMs = Just _@ for
a finite total cap (e.g. CI scenarios).
-}
module Cardano.Node.Client.UTxOIndexer.Probe (
    -- * Config
    ProbeConfig (..),
    defaultProbeConfig,

    -- * Probe
    waitForNodeReady,

    -- * Utilities
    msToMicros,
) where

import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Cardano.Node.Client.UTxOIndexer.Trace (
    IndexerEvent (..),
 )
import Control.Concurrent.Async (withAsync)
import Control.Exception (
    Exception,
    SomeAsyncException,
    SomeException,
    fromException,
    throwIO,
 )
import Control.Monad.Catch (Handler (..))
import Control.Retry (
    RetryAction (..),
    RetryStatus (..),
    capDelay,
    exponentialBackoff,
    limitRetriesByCumulativeDelay,
    recoveringDynamic,
 )
import Control.Tracer (Tracer, traceWith)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Ouroboros.Consensus.Ledger.Query (Query (GetChainPoint))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Point qualified as Network.Point
import System.Timeout (timeout)

{- | Pure configuration for 'waitForNodeReady'. Constructed
once at daemon startup from CLI flags.
-}
data ProbeConfig = ProbeConfig
    { pcAttemptTimeoutMs :: !Word64
    -- ^ Per-attempt cap on the LSQ acquire+query call.
    -- After this many milliseconds the probe assumes the
    -- node hasn't finished loading its ChainDB yet,
    -- emits 'IndexerNodeReplaying', and retries.
    , pcRetryBaseMs :: !Word64
    -- ^ Base of the exponential backoff between probe
    -- attempts (ms).
    , pcRetryMaxMs :: !Word64
    -- ^ Cap of the exponential backoff between probe
    -- attempts (ms).
    , pcTotalTimeoutMs :: !(Maybe Word64)
    -- ^ Total cap on the probe loop.
    -- 'Nothing' = unbounded (default): the probe waits
    -- forever, emitting 'IndexerNodeReplaying' on each
    -- iteration. 'Just n' caps cumulative retry delay at
    -- @n@ ms; once exceeded, the most recent failure is
    -- rethrown.
    }
    deriving stock (Show, Eq)

{- | Defaults: per-attempt 5 s, between-attempts 250 ms→5 s,
total cap unbounded. Matches the user-facing semantics
described in @quickstart.md § CLI surface@.
-}
defaultProbeConfig :: ProbeConfig
defaultProbeConfig =
    ProbeConfig
        { pcAttemptTimeoutMs = 5_000
        , pcRetryBaseMs = 250
        , pcRetryMaxMs = 5_000
        , pcTotalTimeoutMs = Nothing
        }

{- | The probe attempt's "node didn't reply within
@pcAttemptTimeoutMs@" failure. Caught by the retry
handler, which emits 'IndexerNodeReplaying' and
re-attempts.
-}
data ProbeAttemptTimeout = ProbeAttemptTimeout
    deriving stock (Show)

instance Exception ProbeAttemptTimeout

{- | The probe attempt observed a tip at Origin. Treated
as "node up but chain not yet loaded" — same retry
behaviour as a timeout.
-}
data ProbeTipAtOrigin = ProbeTipAtOrigin
    deriving stock (Show)

instance Exception ProbeTipAtOrigin

{- | Probe the upstream cardano-node until it serves a
non-Origin chain tip via LocalStateQuery. Blocks until
the node is ready or until 'pcTotalTimeoutMs' is reached.

Emits 'IndexerNodeReplaying' on each retry attempt so
operators can distinguish "alive but warming up" from
"broken".

Async exceptions ('AsyncCancelled', termination signals)
propagate immediately so the daemon can shut down cleanly.
-}
waitForNodeReady ::
    Tracer IO IndexerEvent ->
    ProbeConfig ->
    NetworkMagic ->
    -- | Path to the upstream node Unix socket.
    FilePath ->
    IO ()
waitForNodeReady tracer pc magic socketPath = do
    startNs <- getMonotonicTimeNSec
    let basePolicy =
            capDelay
                (msToMicros (pcRetryMaxMs pc))
                (exponentialBackoff (msToMicros (pcRetryBaseMs pc)))
        policy = case pcTotalTimeoutMs pc of
            Nothing -> basePolicy
            Just totalMs ->
                limitRetriesByCumulativeDelay
                    (msToMicros totalMs)
                    basePolicy
    recoveringDynamic policy [retryHandler startNs] (const probeOnce)
  where
    probeOnce :: IO ()
    probeOnce = do
        lsq <- newLSQChannel 16
        ltxs <- newLTxSChannel 16
        withAsync (runNodeClient magic socketPath lsq ltxs) $ \_ -> do
            mPoint <-
                timeout
                    (msToMicros (pcAttemptTimeoutMs pc))
                    (queryLSQ lsq GetChainPoint)
            case mPoint of
                Nothing -> throwIO ProbeAttemptTimeout
                Just (Network.Point Network.Point.Origin) ->
                    throwIO ProbeTipAtOrigin
                Just (Network.Point (Network.Point.At _)) ->
                    pure ()

    retryHandler ::
        Word64 ->
        RetryStatus ->
        Handler IO RetryAction
    retryHandler startNs rs = Handler $ \(e :: SomeException) ->
        case fromException e :: Maybe SomeAsyncException of
            Just _ -> pure DontRetry
            Nothing -> do
                nowNs <- getMonotonicTimeNSec
                let elapsedMs = (nowNs - startNs) `div` 1_000_000
                traceWith
                    tracer
                    ( IndexerNodeReplaying
                        (rsIterNumber rs + 1)
                        elapsedMs
                    )
                pure ConsultPolicy

-- | Convert milliseconds to microseconds, saturating at 'maxBound :: Int'.
msToMicros :: Word64 -> Int
msToMicros ms
    | ms > fromIntegral (maxBound `div` 1_000 :: Int) = maxBound
    | otherwise = fromIntegral ms * 1_000
