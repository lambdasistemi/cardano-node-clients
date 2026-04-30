# Research: utxo-indexer auto-reconnect on N2C peer close

**Feature**: 035-indexer-n2c-reconnect
**Date**: 2026-04-30 (revised after empirical reproduction landed in PR #100)

## Empirical premise (validated)

The bug in https://github.com/lambdasistemi/cardano-node-clients/issues/97 is real and reproducible. The regression test at `test/Cardano/Node/Client/E2E/Issue97ReproSpec.hs` (landed via PR #100 — https://github.com/lambdasistemi/cardano-node-clients/pull/100) drives `runChainSyncN2C` directly with a no-op follower, restarts the upstream cardano-node, and asserts the chain-sync `Async` resolves with a `Left` whose rendered text contains `bearer closed` / `BearerClosed` / `network-mux`. The exception escapes `runChainSyncN2C`'s own catch path because the network-mux bearer-error path bypasses it. This is the contract that justifies the supervisor.

## Codebase findings

### Daemon entrypoint (`lib/Cardano/Node/Client/UTxOIndexer/Daemon.hs`)

- `runDaemon :: DaemonConfig -> IO ()` opens the indexer, detects boot mode via `getResumePoints`, runs `concurrently_ chainAction serverAction`. The `chainAction = runChainSyncN2C ...` site is the single connect point. Today it has no supervisor; an exception escaping `runChainSyncN2C` kills the daemon.

### N2C connection layer (`lib/Cardano/Node/Client/N2C/Connection.hs`)

- Public API: `runNodeClient` (LSQ + LTxS) and `runNodeClientFull` (adds chain-sync). Both block until socket close. No retry/backoff primitives — the supervisor sits *above* these.

### Persistence (`lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs`)

- `getResumePoints` returns `[(SlotNo, BlockHash)]` Fibonacci-thinned from the rollback log. Reused as-is by the supervisor on every retry — no schema changes.
- WarmBoot's `intersectNotFound` correctly fail-closes (introduced in PR #86). This stays.

### Listen socket (`lib/Cardano/Node/Client/UTxOIndexer/Server.hs`)

- `runServer` takes `IO ReadyStatus`. `ReadyStatus` currently has `rsReady`, `rsTipSlot`, `rsProcessedSlot`, `rsSlotsBehind` — extended in this feature with `rsUpstream :: UpstreamStatus`.

### Logging

- `nullTracer` everywhere today. We introduce `IndexerEvent` in a new `Cardano.Node.Client.UTxOIndexer.Trace` module.

## Decisions

### D1. Where the supervisor lives — wrap `runChainSyncN2C` in `Daemon.hs`

**Decision**: Put `runReconnectLoop` in a new `Cardano.Node.Client.UTxOIndexer.Reconnect` module. `Daemon.runDaemon` wraps the `runChainSyncN2C` call in it.

**Rationale**: The N2C connection layer is shared between several clients (LSQ, LTxS, ChainSync). Reconnect policy is indexer-specific because it depends on the indexer's resume points. Keeping the supervisor in indexer-land lets each consumer pick its own policy.

### D2. Backoff implementation — `retry` library, not hand-rolled

**Decision**: Use `Control.Retry` from `retry-0.9.3.1` (https://hackage.haskell.org/package/retry-0.9.3.1/docs/Control-Retry.html). The package is already in this repo's transitive dependency closure (verified via `dist-newstyle/cache/plan.json`); adding `, retry` to `cardano-node-clients.cabal`'s library `build-depends` is a one-line cabal change with no flake impact.

**Implementation**:
- Backoff = `capDelay rpMaxMs (fullJitterBackoff rpInitialMs)` — full-jitter exponential per AWS Architecture Blog pattern.
- Loop = `retryingDynamic` with a value-level `RetryAction`: `ConsultPolicy` when the action returned `Left _` (synchronous failure), `DontRetry` when `Right ()` or when the failure is async (caller wants to shut down).

**Rationale**:
- `retry` is the canonical Cardano-Haskell choice. cardano-wallet uses `recoveringDynamic` in the equivalent code path (`lib/network-layer/src/Cardano/Wallet/Network/Implementation.hs:1261-1270` in https://github.com/cardano-foundation/cardano-wallet).
- Replaces ~80 LOC of hand-rolled `upperBoundMs`/`nextDelayMs`/`msToMicros`/`loop` with a single `retryingDynamic` call.
- `RetryAction(..)` (`ConsultPolicy | ConsultPolicyOverrideDelay Int | DontRetry`) gives value-level "recoverable vs fatal" without exception-typing gymnastics.

### D3. Exception scope — broad `try`, propagate `SomeAsyncException`

**Decision**: Wrap `runChainSyncN2C` in `try @SomeException`. On `Left e`, check `fromException @SomeAsyncException`; rethrow if matched, otherwise feed to the retry policy as a recoverable failure.

**Rationale**: Pattern-matching specific mux constructors is brittle across `ouroboros-network` upgrades. Treating *any* synchronous exception from `runChainSyncN2C` as "connection is dead, retry" is robust. Async cancellation is the only thing we must propagate.

### D4. Surface upstream status to consumers via `ReadyStatus`

**Decision**: Extend `ReadyStatus` with `rsUpstream :: UpstreamStatus`, a sum of `UpstreamConnected | UpstreamDisconnected DisconnectInfo`. JSON encoder emits `"upstream"` only when disconnected (additive, backwards-compatible). When upstream is disconnected, the encoder defensively forces `ready=false` regardless of the in-memory value.

**Rationale**: FR-005/FR-006 require a defined response during disconnect. `ready=false` plus a structured reason is the simplest informative answer. `utxos_at`/`await` continue against persisted state.

### D5. Logging — `IndexerEvent` ADT + default stderr renderer

**Decision**: New `IndexerEvent` ADT with constructors `IndexerStarted`, `IndexerDisconnected`, `IndexerReconnecting`, `IndexerReconnected`, `IndexerStopped`, **`IndexerNodeReplaying`** (new — emitted by the probe loop while the upstream node hasn't yet completed ChainDB load). Default `defaultStderrTracer` renders one line per event with an ISO-8601 timestamp and `indexer event=<name>` grep tag. Library exposes `Tracer IO IndexerEvent` so embedding consumers can route events into their own tracer.

### D6. Node-ready probe — LSQ tip query with unbounded timeout

**Decision**: New `Cardano.Node.Client.UTxOIndexer.Probe` module exposing `waitForNodeReady`. Opens an LSQ-only N2C session, sends `MsgAcquire VolatileTip`, runs `GetCurrentTip`, succeeds when the response is non-Origin. Wrapped in `Control.Retry.recoverAll (capDelay maxBound (exponentialBackoff 250_000))` so it retries on transport-level errors. On each retry, emits `IndexerNodeReplaying` so the operator sees progress.

**Rationale**:
- Per `Ouroboros.Network.Protocol.LocalStateQuery.Type:114-128`, `VolatileTip` "cannot fail to be acquired" — failure modes are eliminated by construction.
- `GetCurrentTip` is constant-time and era-independent.
- cardano-node 10.7.0 has **no protocol-level "I'm not ready" message**. The LSQ server isn't even started until ChainDB has finished loading. So during chain replay, our `MsgAcquire` simply hangs with no response. The probe must therefore be timeout-based.
- **Default timeout: unbounded.** Chain replay on a real testnet can take minutes or longer; we don't want to give up. Operators who want a finite cap can set `--node-ready-timeout-ms`.
- The probe replaces the 10s `threadDelay` in the test harness's `restartNode` (which was a workaround for "we don't know when the new node is ready") AND lives inside the supervisor (so production reconnect doesn't depend on timing).

**Alternatives considered**:
- *NodeToClient handshake-only probe*: handshake and LSQ both come up at the same moment, after `openChainDB` (per `ouroboros-consensus-diffusion/src/Ouroboros/Consensus/Node.hs:519,983`). Probing handshake separately gives no extra information.
- *Prometheus `blockReplayProgress` scrape*: cardano-node exposes a gauge at `127.0.0.1:12798/metrics` by default, available during replay. Cleaner UX (we'd see "replaying, 23%") but adds an `http-client` dep and depends on the deployment configuring `PrometheusSimple`. **Deferred to https://github.com/lambdasistemi/cardano-node-clients/issues/101.**
- *Stricter probe (tip ≥ baseline)*: would catch the case where the new node restarts on an empty database. Out of scope here — the antithesis testnet uses persistent volumes and chain divergence isn't a realistic failure mode.

### D7. CLI flags

**Decision**: Four optional flags, all with sensible defaults:

- `--reconnect-initial-ms` (default 1000) — full-jitter backoff base.
- `--reconnect-max-ms` (default 30000) — full-jitter backoff cap.
- `--reconnect-reset-threshold-ms` (default 30000) — chain-sync run duration that resets the supervisor's failure counter.
- `--node-ready-timeout-ms` (default unset = unbounded) — per-attempt cap on the LSQ probe loop. When unset, the probe waits forever (with `IndexerNodeReplaying` events emitted periodically).

### D8. E2E test approach

**Decision**: One E2E spec, `UTxOIndexerReconnectSpec`, exercising US1/US2/US3 in a single test against a real devnet:

1. Boot devnet via `withRestartableCardanoNode` (the helper landed in PR #100).
2. Start the daemon with a captured tracer.
3. Wait for `ready=true`, capture pre-restart `processedSlot`.
4. Restart the relay.
5. Assert the daemon's `Async` is still running.
6. Assert `ready` returns an `upstream` object with `status="disconnected"` at some point during the gap.
7. Assert `utxos_at` is still answered (no EOF) during the gap.
8. Wait for chain-sync to resume — assert `processedSlot` strictly advances past pre-restart value.
9. Assert the captured event stream contains `IndexerStarted` (=1), `IndexerDisconnected` (≥1), `IndexerReconnecting` (≥1), `IndexerReconnected` (≥1).

The test no longer needs the 10 s grace inside `restartNode` — once the probe + supervisor are in place, the supervisor itself waits for the new node to be ready before reattempting chain-sync, so reconnect is timing-independent.

## Open questions

None. All clarifications resolved. The Prometheus-based UX improvement is captured separately in https://github.com/lambdasistemi/cardano-node-clients/issues/101.
