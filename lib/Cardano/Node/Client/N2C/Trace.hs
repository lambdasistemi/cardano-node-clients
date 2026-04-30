{- |
Module      : Cardano.Node.Client.N2C.Trace
Description : Structured indexer events for tracing
License     : Apache-2.0

ADT carried by the indexer's
'Control.Tracer.Tracer' 'N2CEvent'. Each lifecycle
transition emits exactly one event.

For executables, 'defaultStderrTracer' renders events as
single-line ISO-8601-prefixed text that's easy to grep
out of mixed-source container logs. Library consumers
(e.g. embedding daemons) can route events into their
own tracer.
-}
module Cardano.Node.Client.N2C.Trace (
    N2CEvent (..),
    StopReason (..),
    nullN2CTracer,
    defaultStderrTracer,
    renderN2CEvent,
) where

import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Tracer (Tracer (..), nullTracer)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (
    defaultTimeLocale,
    formatTime,
 )
import Data.Word (Word64)
import System.IO (Handle, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

{- | Indexer lifecycle event. Constructors are emitted at
the points described in @data-model.md § N2CEvent@.
Field positions are stable; future variants will be added
as new constructors rather than by extending existing ones.
-}
data N2CEvent
    = -- | Daemon entry: listen-socket path and (optional)
      -- RocksDB path. Emitted once per process.
      IndexerStarted !FilePath !(Maybe FilePath)
    | -- | Upstream chain-sync run terminated. The 'Text'
      -- is a short, human-readable reason
      -- (@displayException@ truncated to ~80 chars).
      IndexerDisconnected !Text
    | -- | The probe loop is waiting for the upstream node
      -- to finish loading its ChainDB. Emitted once per
      -- failed probe attempt (LSQ acquire that didn't
      -- reply within the per-attempt budget). Operators
      -- can use the attempt counter and elapsed time to
      -- distinguish "alive, replaying" from "broken".
      IndexerNodeReplaying !Int !Word64
    | -- | Supervisor is about to retry chain-sync.
      -- @attempt@ is 1-based; @waitMs@ is the jittered
      -- delay this attempt slept before connecting.
      IndexerReconnecting !Int !Word64
    | -- | A fresh chain-sync run survived the reset
      -- threshold. @resumeSlot@ is the most recently
      -- applied slot at the moment the supervisor
      -- declared the run healthy; @elapsedMs@ is the
      -- total time spent disconnected since the prior
      -- 'IndexerDisconnected'.
      IndexerReconnected !(Maybe SlotNo) !Word64
    | -- | Daemon exit. Emitted exactly once per process,
      -- including on async cancellation.
      IndexerStopped !StopReason
    deriving stock (Show, Eq)

{- | Reason the daemon stopped. 'StoppedAsync' is set when
an async exception (e.g. 'AsyncCancelled') propagates
through the supervisor; 'StoppedNormally' is reserved for
clean process termination paths.
-}
data StopReason
    = StoppedNormally
    | StoppedAsync
    deriving stock (Show, Eq)

{- | Drop every event. Useful for tests and for embedding
daemons before their real tracer is wired through
'DaemonConfig'.
-}
nullN2CTracer :: Tracer IO N2CEvent
nullN2CTracer = nullTracer

{- | Render an event as a single key=value line. Used by
'defaultStderrTracer' and exposed for tests that need to
parse the human-readable format.

Format:

@
indexer event=<name> [k1=v1 k2=v2 ...]
@

The leading @indexer @ tag makes the line easy to grep
out of mixed-source container logs.
-}
renderN2CEvent :: N2CEvent -> Text
renderN2CEvent ev =
    Text.pack "indexer " <> case ev of
        IndexerStarted sp dbp ->
            kv "event" "started"
                <> ksp "socketPath" sp
                <> ksp "dbPath" (fromMaybe "<in-memory>" dbp)
        IndexerDisconnected reason ->
            kv "event" "disconnected"
                <> kvText "reason" reason
        IndexerNodeReplaying attempt elapsedMs ->
            kv "event" "node-replaying"
                <> kshow "attempt" attempt
                <> kshow "elapsedMs" elapsedMs
        IndexerReconnecting attempt waitMs ->
            kv "event" "reconnecting"
                <> kshow "attempt" attempt
                <> kshow "waitMs" waitMs
        IndexerReconnected mSlot elapsedMs ->
            kv "event" "reconnected"
                <> ksp
                    "resumeSlot"
                    ( case mSlot of
                        Nothing -> "<none>"
                        Just (SlotNo s) -> show s
                    )
                <> kshow "elapsedMs" elapsedMs
        IndexerStopped reason ->
            kv "event" "stopped"
                <> ksp
                    "reason"
                    ( case reason of
                        StoppedNormally -> "normal"
                        StoppedAsync -> "async"
                    )
  where
    kv :: Text -> Text -> Text
    kv k v = k <> Text.pack "=" <> v
    ksp :: Text -> String -> Text
    ksp k v = Text.pack " " <> k <> Text.pack "=" <> Text.pack v
    kshow :: (Show a) => Text -> a -> Text
    kshow k v = ksp k (show v)
    kvText :: Text -> Text -> Text
    kvText k v = Text.pack " " <> k <> Text.pack "=" <> v

{- | Lock for serializing writes to the shared output
'Handle'. Without this, two events emitted concurrently
could interleave at the byte level.
-}
stderrLock :: MVar ()
stderrLock = unsafePerformIO (newMVar ())
{-# NOINLINE stderrLock #-}

{- | Tracer that writes one line per event to a 'Handle'
with a serializing lock. The line is prefixed with an
ISO-8601 UTC timestamp plus a level tag.

Format:

@
2026-04-30T12:34:56.789Z INFO indexer event=disconnected reason=...
@
-}
handleTracer :: Handle -> Tracer IO N2CEvent
handleTracer h = Tracer $ \ev -> do
    now <- getCurrentTime
    let ts =
            formatTime
                defaultTimeLocale
                "%Y-%m-%dT%H:%M:%S%QZ"
                now
        line =
            ts <> " INFO " <> Text.unpack (renderN2CEvent ev)
    withMVar stderrLock $ \() -> hPutStrLn h line

{- | Default tracer for the @utxo-indexer@ executable.
Routes events to 'stderr'.
-}
defaultStderrTracer :: Tracer IO N2CEvent
defaultStderrTracer = handleTracer stderr
