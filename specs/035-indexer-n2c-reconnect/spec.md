# Feature Specification: utxo-indexer auto-reconnect on N2C peer close

**Feature Branch**: `035-indexer-n2c-reconnect`
**Created**: 2026-04-29 (revised 2026-04-30 after research + reproducer)
**Status**: Draft
**Input**: User description: "utxo-indexer auto-reconnect on N2C peer close — see https://github.com/lambdasistemi/cardano-node-clients/issues/97"
**Bug regression test (already on main)**: https://github.com/lambdasistemi/cardano-node-clients/pull/100
**Prometheus follow-up**: https://github.com/lambdasistemi/cardano-node-clients/issues/101

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Indexer survives upstream relay restart (Priority: P1)

An operator runs `utxo-indexer` as a long-lived daemon attached to a single Cardano relay over a local node socket (Node-to-Client / N2C). The relay is part of a fault-injection workload and is restarted periodically. The operator expects the indexer to keep running across each relay restart, transparently re-attaching to the relay when it comes back, and resuming chain-sync from the last block it had already applied.

**Why this priority**: This is the entire point of the feature. Without it the indexer exits on every peer disconnect, forcing the orchestrator to restart the process; downstream consumers see EOF on the listen socket and must implement their own reconnect-the-indexer loops on top of reconnect-the-relay loops. With it, peer restarts become a transient, observable event rather than a crash.

**Independent Test**: Start the indexer pointed at a relay, wait for it to reach steady state (`ready=true`), restart the relay container, and confirm: (a) the indexer process does not exit, (b) the listen socket continues to accept connections throughout, (c) within a short window after the relay returns, the indexer reports `ready=true` again at the new tip without having re-indexed from genesis.

**Acceptance Scenarios**:

1. **Given** the indexer is running and synced to tip, **When** the upstream relay closes the node socket (e.g. container restart), **Then** the indexer process keeps running, the listen socket keeps accepting connections, and the indexer logs a single structured disconnect event (no uncaught-exception backtrace).
2. **Given** the indexer has detected an upstream disconnect, **When** the relay becomes reachable again, **Then** the indexer reconnects, resumes chain-sync from its last applied block, and reports `ready=true` once it has caught up to the new tip — without re-indexing already-applied blocks.
3. **Given** the upstream relay is repeatedly restarted in quick succession, **When** each restart occurs, **Then** the indexer reconnects each time without leaking resources, exiting, or exhausting attempt counters.

---

### User Story 2 - Read primitives degrade gracefully during disconnect (Priority: P2)

A downstream consumer (e.g. `cardano-tx-generator`, `asteria-stub`) is talking to the indexer over the listen socket and issues a read primitive (`utxos_at`, `await`, `ready`) while the upstream relay is down. The consumer expects a defined, non-fatal response that signals "indexer is temporarily unable to serve up-to-date answers" — not an EOF on the socket and not a hang.

**Why this priority**: Without this, every peer restart triples in cost: relay restart + indexer restart + downstream consumer reconnect. Consumers have to encode the indexer's lifecycle into their own retry logic. With graceful degradation, consumers only need a normal "wait until ready" loop.

**Independent Test**: With the upstream relay stopped, open a fresh consumer connection to the indexer's listen socket and issue each read primitive. Each call must return a defined response (not EOF, not a closed connection). After the relay is restarted and the indexer reconnects, the same calls must succeed normally.

**Acceptance Scenarios**:

1. **Given** the indexer's upstream peer is disconnected, **When** a consumer calls `ready`, **Then** the indexer responds with `ready=false` and a reason indicating upstream is unavailable.
2. **Given** the indexer's upstream peer is disconnected, **When** a consumer calls `utxos_at` or `await`, **Then** the indexer either returns a defined "not-ready" response or blocks until reconnect succeeds — but does not close the listen connection.
3. **Given** the indexer reconnects upstream, **When** a previously-blocked consumer call resumes, **Then** it returns a result based on the current (post-reconnect) chain state.

---

### User Story 3 - Disconnect/reconnect events are observable (Priority: P3)

An operator inspecting container logs after a fault-injection run wants to distinguish actual indexer faults from routine peer flapping. They expect every disconnect and every reconnect attempt to appear as a single, structured log event with enough information to correlate with relay-side events.

**Why this priority**: Once US1 and US2 are in place, peer restarts stop being crashes — but they still need to be visible. Without structured events, fault-injection runs become hard to triage because routine reconnect noise is indistinguishable from real bugs.

**Independent Test**: Run a fault-injection workload that restarts the relay N times, then grep the indexer's stderr/log output. Confirm exactly N "disconnect" events and N "reconnect succeeded" events, each tagged with peer identity, an attempt counter, and the elapsed wait. No uncaught-exception backtraces appear.

**Acceptance Scenarios**:

1. **Given** the upstream peer closes the socket, **When** the indexer detects the close, **Then** a single structured log event is emitted naming the peer and the reason.
2. **Given** the indexer is in a reconnect loop, **When** each retry attempt is made, **Then** a structured event records the attempt number and the wait that preceded it.
3. **Given** the indexer successfully reconnects, **When** the new connection enters chain-sync, **Then** a structured event records the resume slot and total time spent disconnected.

---

### Edge Cases

- **Peer never returns**: The indexer must continue retrying with bounded backoff indefinitely rather than giving up and exiting. The orchestrator's `restart: always` policy stops being load-bearing for normal peer flapping.
- **Disconnect during initial bootstrap**: A disconnect that happens before any block has been applied must still be handled — the indexer must reconnect and continue bootstrapping from genesis (or its configured starting point), not exit.
- **Disconnect mid-rollback**: A disconnect that interrupts an in-progress rollback must leave persisted state in a consistent position so that resume on reconnect is correct.
- **Rapid flapping**: Several disconnects in quick succession must not exhaust resources, leak file descriptors, or grow the backoff so far that the indexer takes minutes to recover from a transient blip.
- **Listen-socket accept during disconnect**: New consumer connections opened while the upstream is down must be accepted and handled (returning the documented degraded response), not refused.
- **Shutdown while disconnected**: A termination signal received while the indexer is in its reconnect loop must still result in a clean shutdown without waiting for the upstream to return.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The indexer MUST continue running when its upstream Cardano relay closes the node socket; it MUST NOT exit the process as a result of an upstream disconnect.
- **FR-002**: The indexer MUST automatically attempt to re-establish the upstream chain-sync connection after a disconnect, using a bounded, jittered backoff strategy.
- **FR-003**: On successful reconnect, the indexer MUST resume chain-sync from the last block-no it had previously applied, using already-persisted state; it MUST NOT re-index from genesis.
- **FR-004**: The indexer's listen socket MUST remain open and continue accepting consumer connections throughout the entire disconnect/reconnect window.
- **FR-005**: While the upstream is disconnected, the indexer MUST respond to `ready` queries with a defined response indicating the indexer is not currently ready and naming "upstream unavailable" as the reason.
- **FR-006**: While the upstream is disconnected, the indexer MUST handle `utxos_at` and `await` requests with a defined response (either an "indexer not ready" reply or a wait-until-reconnect behaviour) — it MUST NOT close consumer connections or return EOF.
- **FR-007**: The indexer MUST emit a structured log event on every detected upstream disconnect, including peer identity and the reason for disconnect.
- **FR-008**: The indexer MUST emit a structured log event on every reconnect attempt, including the attempt counter and the wait elapsed before that attempt.
- **FR-009**: The indexer MUST emit a structured log event on every successful reconnect, including the resume position and the total time spent disconnected.
- **FR-010**: The indexer MUST NOT surface upstream disconnect as an uncaught-exception backtrace in normal operation.
- **FR-011**: The indexer MUST shut down cleanly in response to a termination signal even when it is currently in a reconnect-retry loop.
- **FR-012**: The reconnect backoff MUST have an upper bound (cap) so that the time between attempts does not grow without limit and so that recovery from a long outage completes in a bounded window once the peer returns.
- **FR-013**: The reconnect backoff MUST include randomisation (jitter) so that, in deployments running multiple indexers, simultaneous reconnect storms are dampened.

### Key Entities

- **Upstream peer**: The single Cardano relay node the indexer is chain-synced to over a local node socket. Identified by socket path. Its lifecycle is independent of the indexer's lifecycle.
- **Last applied position**: The block-no (and slot) of the most recent block whose effects have been durably persisted by the indexer. Used as the resume point on reconnect.
- **Reconnect attempt**: A single try at re-establishing the upstream chain-sync connection. Has an attempt counter and an associated wait (subject to backoff and jitter).
- **Disconnect event** / **reconnect event**: Structured records emitted to the indexer's log stream describing peer-lifecycle transitions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a workload that restarts the upstream relay 50 times in succession, the indexer process exits zero times.
- **SC-002**: After each upstream restart, the indexer returns to `ready=true` within a small multiple (≤ 3×) of the relay's own restart-to-tip time, without re-indexing already-applied blocks.
- **SC-003**: During a disconnect window, 100% of consumer `ready` calls receive a defined "not-ready, upstream unavailable" response within the consumer's normal request timeout — none EOF or hang indefinitely.
- **SC-004**: Indexer container logs contain exactly one structured "disconnect" event and one structured "reconnect succeeded" event per peer-restart cycle, and zero uncaught-exception backtraces attributable to peer disconnect.
- **SC-005**: With the upstream relay permanently down, the indexer's listen socket continues to accept new consumer connections for at least one hour (i.e. the reconnect loop does not stall the daemon's listener).
- **SC-006**: The downstream consumers (`cardano-tx-generator`, `asteria-stub`) can run against the indexer in a fault-injection workload **without** orchestrator-level `restart: always` on the indexer container, and observe no `ready` EOFs caused by indexer process exits.

## Assumptions

- **Single-peer scope**: The indexer is attached to exactly one upstream relay via one node socket. Multi-peer failover is out of scope for this feature.
- **Persistence already present**: The indexer's persistent state (established by PR #90 — https://github.com/lambdasistemi/cardano-node-clients/pull/90) is sufficient to resume chain-sync from the last applied block. The relay's chain database is similarly preserved across SIGTERM (the production scenario uses a persistent volume); the test harness assumes the same property.
- **Backoff defaults**: Supervisor backoff defaults to 1 s base growing to a 30 s cap, full-jitter exponential, implemented via `Control.Retry`'s `capDelay (fullJitterBackoff _)`. Exposed as `--reconnect-initial-ms` / `--reconnect-max-ms` / `--reconnect-reset-threshold-ms`.
- **Probe-then-connect**: Before each chain-sync attempt the supervisor probes the upstream node via LSQ (`Acquire VolatileTip` + `GetCurrentTip`) and only attempts chain-sync when the probe sees a non-Origin tip. This sidesteps the bootup race where cardano-node binds the socket before its ChainDB has finished loading.
- **Probe timeout default = unbounded**: The `--node-ready-timeout-ms` flag defaults to unset. Chain replay on a real testnet can take minutes or longer; the probe waits forever and emits periodic `IndexerNodeReplaying` events so operators can see "alive but warming up" in logs. Operators wanting a finite cap (CI scenarios) set the flag explicitly.
- **Retry forever**: The supervisor retries chain-sync failures indefinitely with capped backoff. No orchestrator-level `restart: always` needed on the indexer container.
- **Same N2C protocol surface**: No protocol changes; the chain-sync protocol used after reconnect is the same one used on cold start.
- **Source issue and motivation**: https://github.com/lambdasistemi/cardano-node-clients/issues/97. Bug confirmed by reproducer in PR https://github.com/lambdasistemi/cardano-node-clients/pull/100 (already on main). Primary downstream consumer: PR https://github.com/lambdasistemi/cardano-node-clients/pull/94. Next consumer: https://github.com/cardano-foundation/cardano-node-antithesis/pull/74.
