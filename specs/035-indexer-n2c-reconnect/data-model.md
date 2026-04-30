# Data Model: utxo-indexer auto-reconnect on N2C peer close

**Feature**: 035-indexer-n2c-reconnect
**Date**: 2026-04-30

This feature adds four pure types and extends one existing type. No persistence schema changes.

## Entities

### `ReconnectPolicy` (new — `Cardano.Node.Client.UTxOIndexer.Reconnect`)

Pure configuration for the reconnect supervisor. Constructed once at daemon startup from CLI flags.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `rpInitialMs` | `Word64` | `1000` | Base of the full-jitter exponential backoff (ms). |
| `rpMaxMs` | `Word64` | `30000` | Cap of the full-jitter backoff window (ms). |
| `rpResetThresholdMs` | `Word64` | `30000` | Minimum chain-sync run duration after which the supervisor resets the failure counter to zero. |

**Invariants**: `rpInitialMs ≤ rpMaxMs`; `rpResetThresholdMs > 0`.

**Mapping to `Control.Retry`**: `capDelay (rpMaxMs * 1000) (fullJitterBackoff (rpInitialMs * 1000))` — `retry`'s policy combinators take microseconds.

---

### `ProbeConfig` (new — `Cardano.Node.Client.UTxOIndexer.Probe`)

Pure configuration for the LSQ tip probe.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pcTimeoutMs` | `Maybe Word64` | `Nothing` | Per-attempt LSQ-acquire timeout. `Nothing` = unbounded (the probe waits forever for chain replay to complete). |
| `pcRetryBaseMs` | `Word64` | `250` | Base of the probe's own exponential backoff between retry attempts. |
| `pcRetryMaxMs` | `Word64` | `5_000` | Cap of the probe's retry-between-attempts backoff. |

The probe has its own (small) backoff for transport-level retries (e.g. ConnectionRefused while the node socket is being bound) — separate from the supervisor's backoff for chain-sync failures.

---

### `UpstreamStatus` (new — `Cardano.Node.Client.UTxOIndexer.Reconnect`)

| Constructor | Fields | Meaning |
|-------------|--------|---------|
| `UpstreamConnected` | — | Chain-sync mux session is live. |
| `UpstreamDisconnected` | `DisconnectInfo` | Supervisor is in the reconnect loop. |

```haskell
data DisconnectInfo = DisconnectInfo
  { diReason  :: !Text     -- short, human-readable reason
  , diAttempt :: !Int      -- current attempt counter (1-based)
  , diSinceMs :: !Word64   -- monotonic ms since the disconnect was first observed
  }
```

**Encoding**: `Server.hs`'s JSON renderer emits the `upstream` field on `ready` responses only when `UpstreamDisconnected`. See `contracts/control-wire.md`.

---

### `IndexerEvent` (new — `Cardano.Node.Client.UTxOIndexer.Trace`)

ADT carried by `Tracer IO IndexerEvent`.

| Constructor | Fields | Emitted at |
|-------------|--------|-----------|
| `IndexerStarted` | `FilePath` (listen socket), `Maybe FilePath` (db path) | once on `runDaemon` entry |
| `IndexerDisconnected` | `Text` (reason) | each time `runChainSyncN2C` returns/throws |
| `IndexerNodeReplaying` | `Int` (probe attempt), `Word64` (elapsed ms) | each probe iteration that didn't get a response (i.e. the upstream node is still loading its ChainDB) |
| `IndexerReconnecting` | `Int` (attempt), `Word64` (waitMs) | each supervisor retry attempt before the sleep |
| `IndexerReconnected` | `Maybe SlotNo` (resume slot), `Word64` (elapsedMs) | first time a chain-sync run survives `rpResetThresholdMs` after at least one failure |
| `IndexerStopped` | `StopReason` | on daemon exit (incl. async cancellation) |

`StopReason = StoppedNormally | StoppedAsync`.

The `IndexerNodeReplaying` constructor is the operationally-meaningful new one: it lets operators see "the relay is alive but loading" while the supervisor's probe waits.

---

### `ReadyStatus` (extended — `Cardano.Node.Client.UTxOIndexer.Server`)

```haskell
data ReadyStatus = ReadyStatus
  { rsReady         :: !Bool
  , rsTipSlot       :: !(Maybe SlotNo)
  , rsProcessedSlot :: !(Maybe SlotNo)
  , rsSlotsBehind   :: !(Maybe Word64)
  , rsUpstream      :: !UpstreamStatus    -- NEW
  }
```

**Invariant**: `rsUpstream = UpstreamDisconnected _ ⇒ rsReady = False`. Encoder enforces this on the wire.

**Backwards compatibility**: JSON encoder emits `upstream` only when `rsUpstream = UpstreamDisconnected _`. Existing consumers ignoring unknown fields are unaffected.

---

## State Transitions (supervisor)

```
                   ┌────────────────────────────┐
                   ▼                            │
   ┌───────────────────────┐                    │
   │ Probing (LSQ tip      │  probe replies     │
   │ acquire VolatileTip)  │  with non-Origin   │
   └───────────────────────┘  tip               │
              │                                 │
              ▼                                 │
   ┌───────────────────────┐  runChainSyncN2C   │
   │ Connected (chain-sync │  returns/throws    │
   │ session running)      │  ─────────────►   ─┘
   └───────────────────────┘
              │
              ▼
       AsyncCancelled
       rethrown for
       clean shutdown
```

**Counter reset**: chain-sync run survived ≥ `rpResetThresholdMs` ⇒ reset failure counter to 1 for the next disconnect.

---

## Persistence

**No changes.** Resume points come from the existing `getResumePoints`. The supervisor recomputes them on every retry so it always uses the latest persisted state.
