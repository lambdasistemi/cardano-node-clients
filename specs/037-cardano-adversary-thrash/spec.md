# Feature Specification: chain_sync_thrash endpoint

**Feature Branch**: `037-cardano-adversary-thrash`
**Created**: 2026-04-30
**Status**: Draft
**Input**: User description: "Second misbehaviour endpoint of the cardano-adversary daemon. On a single open N2N chain-sync connection, repeatedly issue MsgFindIntersect to a different randomly-chosen point and never finish the sync. Stresses the producer's intersection-finding cache. Same control-socket NDJSON shape as chain_sync_flap (036)."

## Background

[`036-cardano-adversary`][036] established the daemon and the
`chain_sync_flap` endpoint, where each request opens N concurrent
connections, each one issues one `MsgFindIntersect` and pulls
`limit` blocks before disconnecting. That exercises connection
churn but only ever sends **one** intersect per connection.

A complementary archetype: stay on **one** connection, repeatedly
issue `MsgFindIntersect` to different points without ever pulling
blocks. The producer side has to maintain a per-peer search context
and keep up with rapid pivots through the volatile chain. This is
the canonical "intersection-finding cache thrash" test.

## User Scenarios & Testing *(mandatory)*

The primary user is the **Antithesis test composer** firing one
NDJSON request per tick. Secondary user is the **operator** wiring
the daemon into the testnet.

### User Story 1 — Thrash a single peer's intersection cache (Priority: P1)

The composer fires a single tick; the daemon opens one N2N
chain-sync connection to a randomly-chosen producer, completes the
handshake, and within a bounded time window issues
`intersect_count` `MsgFindIntersect` messages to randomly-chosen
points drawn from the chain-points file, with `settle_ms`
milliseconds between each. After the last one it disconnects.

**Why this priority**: This is the entire endpoint. There is no
useful sub-feature.

**Independent Test**: Stand up the daemon against a devnet whose
`tracer-sidecar` has populated the chain-points file. Send one
request with `intersect_count=10, settle_ms=50`. Verify (a) the
daemon responds `{"ok": true, ...}`, (b) the producer's tracer
log shows ~10 `FindIntersect` events from the adversary peer
within the same connection ID, (c) no `MsgRequestNext` events
from the same peer.

**Acceptance Scenarios**:

1. **Given** the daemon is running and the chain-points file has
   at least one parseable point, **When** the composer sends
   `{"chain_sync_thrash":{"seed":S,"intersect_count":N,"settle_ms":W}}`,
   **Then** the daemon opens exactly one N2N chain-sync
   connection, issues N `MsgFindIntersect` messages with W ms
   between them, then disconnects, and responds with
   `{"ok": true, "details": {"intersectsIssued": N, ...}}`.
2. **Given** the chain-points file is missing or empty, **When**
   the composer fires a request, **Then** the daemon responds
   `{"ok": false, "reason": "no-chain-points-yet"}` (or
   `"no-chain-points-file"`) without dialing any producer.
3. **Given** no `--producer-host` was configured, **When** the
   composer fires a request, **Then** the daemon responds
   `{"ok": false, "reason": "no-producers"}`.
4. **Given** the daemon's TCP connection to the chosen producer
   is refused (host unreachable, port closed), **When** the
   thrash request fires, **Then** the daemon responds
   `{"ok": false, "reason": "connection-refused"}` and never
   crashes.

---

### User Story 2 — Determinism for replay (Priority: P2)

Given a fixed seed and a fixed chain-points file, two thrash
requests must visit the same sequence of producers and the same
sequence of intersect points (modulo network non-determinism on the
producer side).

**Why this priority**: Useful for debugging / triage. If a thrash
caused a finding, replaying the same seed should reproduce it.

**Acceptance Scenarios**:

1. **Given** the same `seed` and the same chain-points file,
   **When** two thrash requests are fired, **Then** the chosen
   producer host and the sequence of intersect points selected for
   `MsgFindIntersect` are byte-identical.

---

## Functional Requirements

- **FR-001** A new top-level NDJSON request shape
  `{"chain_sync_thrash": {"seed": uint64, "intersect_count":
  uint16, "settle_ms": uint16}}` SHALL be accepted on the
  daemon's control socket. Field names match
  `contracts/control-wire.md`.
- **FR-002** The daemon SHALL select exactly one producer host from
  `--producer-host` using the request's `seed` (via
  `splitFromSeed`).
- **FR-003** The daemon SHALL open exactly one chain-sync N2N
  connection per request. After the connection completes its
  intersect loop the daemon SHALL close it and return.
- **FR-004** The daemon SHALL issue `intersect_count`
  `MsgFindIntersect` messages with `settle_ms` milliseconds
  between them. Each intersect's point is drawn from the parsed
  chain-points file via the same `generatePoints` stream used by
  `chain_sync_flap` (036).
- **FR-005** The daemon SHALL NOT send `MsgRequestNext`. The thrash
  loop is **purely** intersect spam.
- **FR-006** Failure modes mirror `chain_sync_flap`:
  `no-chain-points-file`, `no-chain-points-yet`, `no-producers`.
  Add one new mode: `connection-refused` for unreachable
  producers (DNS-not-found or TCP RST).
- **FR-007** The daemon SHALL clamp `intersect_count` to `[1,
  1000]` and `settle_ms` to `[0, 60000]` to keep one tick bounded.
  Clamping is silent — the response carries the actual value
  used.
- **FR-008** Adding the endpoint SHALL NOT regress existing
  endpoints (`ready`, `chain_sync_flap`). The `Server` dispatcher
  must accept the new shape and route to the new hook; existing
  hooks unchanged.
- **FR-009** Wire-spec contract (`control-wire.md`) SHALL be
  updated to document the new endpoint, with the SDK-assertion
  table for the composer driver to map outcomes.

## Non-Functional Requirements

- **NFR-001** Per-tick wall-clock budget: a request with
  `intersect_count=100, settle_ms=50` should complete within
  `100*50ms + connection-setup ≈ 6 s`. Anything longer is a bug.
- **NFR-002** Memory budget: one open connection's chain-sync state
  is sub-MB; idle daemon RSS budget from 036 stands.
- **NFR-003** No persisted state files. The endpoint is stateless
  modulo the chain-points file it shares with `chain_sync_flap`.

## Out of Scope

- Tier 1.3 `chain_sync_slow_loris` (different misbehaviour
  pattern; kept on the same connection but with **slow**
  `MsgRequestNext` instead of intersect thrashing).
- Tier 2 (other mini-protocols).
- The compose-side image bump in `cardano-foundation/cardano-node-antithesis`
  — that's a separate one-line PR after this PR merges.

## Open Questions

- Should the daemon assert that the producer answers each
  `MsgFindIntersect` before sending the next, or is the
  intersect loop purely "send and forget"? **Decision proposed**:
  send-and-forget at the application layer, but the chain-sync
  state machine in `ouroboros-network` already enforces a
  send/receive cadence per protocol. So in practice the daemon
  blocks waiting for the producer's `MsgIntersectFound` /
  `MsgIntersectNotFound` reply between issues. `settle_ms` then
  governs an *additional* sleep on top of the protocol's natural
  RTT.
- Should the same seed produce the same producer choice across
  daemon restarts? **Decision proposed**: yes — the seed alone
  determines both, since the producer list is configured at
  startup and won't change mid-test.

## References

- Wire spec: [`contracts/control-wire.md`](contracts/control-wire.md).
- Plan: [`plan.md`](plan.md).
- Tasks: [`tasks.md`](tasks.md).
- Sibling spec [`036-cardano-adversary`][036] — same daemon, the
  `chain_sync_flap` endpoint.
- Antithesis-side roadmap: https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/docs/components/adversary-roadmap.md
- Tracking issue: https://github.com/lambdasistemi/cardano-node-clients/issues/107

[036]: ../036-cardano-adversary/spec.md
