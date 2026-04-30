# Feature Specification: Cardano Adversary (Antithesis-driven, mini-protocol misbehaviour daemon)

**Feature Branch**: `036-cardano-adversary`
**Created**: 2026-04-30
**Status**: Draft
**Input**: User description: "Long-running Cardano adversary daemon driven by the Antithesis composer; performs configurable misbehaviour against producer / relay nodes through Ouroboros mini-protocols; copies the cardano-tx-generator daemon shape (long-running, NDJSON over UNIX `SOCK_STREAM`, one request per Antithesis tick); steered by an injectable `RandomSource` so the hypervisor can bias adversarial choices; replaces the one-shot Haskell binary in `cardano-foundation/cardano-node-antithesis/components/adversary/`."

## Background

The current adversary in
[`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/components/adversary/src/Adversary/Application.hs)
is a **one-shot binary**: each Antithesis tick spawns it, it runs
`NCONNS` concurrent chain-sync clients, and exits. The choices it
makes at startup come from `newStdGen` — the Antithesis hypervisor
cannot bias them.

This package brings the adversary in line with the existing
[`cardano-tx-generator`](https://github.com/lambdasistemi/cardano-node-clients/tree/main/app/cardano-tx-generator)
shape: a **long-running daemon** that listens on a UNIX control
socket and treats each composer driver invocation as one NDJSON
request → one NDJSON response. Every adversarial action draws from
a `RandomSource` typeclass whose hypervisor implementation reads
from `antithesis_random` so the hypervisor steers the run.

The first iteration of this package is **PR B (scaffold only)**: it
publishes the package, the wire spec, the Docker image, and a
daemon that answers the `ready` probe. Real misbehaviour endpoints
land in subsequent PRs (C, E, etc.) per the
[adversary roadmap](https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/docs/components/adversary-roadmap.md)
on the antithesis side.

## User Scenarios & Testing *(mandatory)*

The primary user is the **Antithesis test composer**, firing short
trigger commands at the daemon during a fault-injection run.
Secondary user is the **operator** who wires the daemon into the
testnet's compose stack and reads its diagnostic output.

### User Story 1 — Readiness probe (Priority: P1)

The composer needs to know the daemon is alive and connected to its
target nodes before sending real misbehaviour requests.

**Why this priority**: Every other story depends on the daemon
being addressable. Without `ready`, composer drivers cannot tell
"the daemon is starting up" from "the daemon crashed" and fault
injection scoring is meaningless.

**Independent Test**: Start the daemon against any reachable
producer hostname, fire `{"ready": null}` repeatedly until the
response carries `{"ready": true}`, assert that response within a
bounded window.

**Acceptance Scenarios**:

1. **Given** the daemon has just started and is still warming up
   internal state (DNS resolution, handshake to producers), **When**
   the composer sends `{"ready": null}`, **Then** the daemon
   responds `{"ready": false, ...details}` with structured details
   identifying the missing readiness component.
2. **Given** the daemon has completed its warmup, **When** the
   composer sends `{"ready": null}`, **Then** the daemon responds
   `{"ready": true, ...details}`.
3. **Given** the daemon is healthy and a malformed JSON line is
   received, **When** the line cannot be parsed, **Then** the
   daemon responds `{"error": "malformed json"}` and closes the
   connection (no crash).

---

### User Story 2 — Reserved misbehaviour endpoint slot (Priority: P1)

The composer needs the wire surface to exist and be non-crashing
even when the underlying misbehaviour is not yet implemented, so
composer drivers can be merged in lock-step with the daemon
endpoints. This is what makes PR B independently shippable.

**Why this priority**: If the wire surface arrives only with the
first real endpoint, the composer-side change in
`cardano-foundation/cardano-node-antithesis` (PR D) blocks on PR C.
Reserving the endpoint at scaffold time decouples them.

**Independent Test**: Send `{"chain_sync_flap": {"seed": <any>,
"limit": 1, "n_conns": 1}}` to the daemon; assert response is
`{"ok": false, "reason": "not-implemented"}` with HTTP-style
explicit not-implemented semantics so composer drivers can map it
to an Antithesis SDK `sdk_unreachable("not-implemented")` until the
real endpoint lands.

**Acceptance Scenarios**:

1. **Given** the daemon is running, **When** the composer sends a
   request to a reserved-but-not-yet-implemented endpoint, **Then**
   the daemon responds with `{"ok": false, "reason":
   "not-implemented"}` and closes the connection.
2. **Given** the daemon is running, **When** the composer sends a
   request to a never-defined endpoint, **Then** the daemon responds
   with `{"error": "unknown request"}` and closes the connection
   (distinct from "not-implemented" which is documented).

---

### User Story 3 — Single shutdown surface (Priority: P2)

The operator needs the daemon to shut down cleanly on `SIGTERM` so
docker-compose container restarts don't leak state files. Mirrors
the tx-generator's shutdown discipline.

**Why this priority**: Operational paper cut, not on the test path.
Skipping it doesn't prevent any composer story from working, but
fixes a class of "container exited 137" reports that obscure real
findings.

**Acceptance Scenarios**:

1. **Given** the daemon is running with an open control-socket
   listener, **When** `SIGTERM` is delivered, **Then** the daemon
   logs a shutdown line, drains any in-flight request, unlinks the
   control socket, and exits 0 within 5 seconds.

---

## Functional Requirements

- **FR-001** The daemon SHALL listen on the UNIX socket path passed
  via `--control-socket`. The socket file SHALL be created with
  `0600` permissions; filesystem permissions are the only
  authentication.
- **FR-002** The daemon SHALL accept exactly one NDJSON request per
  connection. After writing the single-line response it SHALL
  close the connection.
- **FR-003** The daemon SHALL reject malformed JSON requests with
  `{"error": "malformed json"}`.
- **FR-004** The daemon SHALL reject requests whose top-level key
  is not in the documented endpoint set with `{"error": "unknown
  request"}`.
- **FR-005** The daemon SHALL implement the `ready` endpoint
  (defined in `contracts/control-wire.md`) returning a structured
  status with at least an overall `ready: bool` flag.
- **FR-006** The daemon SHALL accept a request to the
  `chain_sync_flap` endpoint and respond `{"ok": false, "reason":
  "not-implemented"}` until the endpoint's logic lands in a later
  PR.
- **FR-007** All randomness drawn by the daemon (warmup ordering,
  any future misbehaviour choice) SHALL flow through a single
  `RandomSource` interface. The default implementation SHALL be
  Antithesis-aware: it SHALL invoke `antithesis_random` when
  available on `PATH` and fall back to `System.Random` otherwise.
- **FR-008** On `SIGTERM` the daemon SHALL drain in-flight
  connections, unlink the control socket, and exit 0 within 5
  seconds.
- **FR-009** The daemon's CLI SHALL accept `--help` and exit 0.
  Required flags MUST be enumerated and any missing required flag
  MUST cause a non-zero exit with a usage line on stderr.
- **FR-010** The package SHALL ship a Nix flake output
  `.#cardano-adversary` (apps + packages + docker-image) following
  the same naming as `cardano-tx-generator`'s flake outputs.
- **FR-011** The Docker image SHALL be published to GHCR by the
  existing `publish-images` workflow under
  `ghcr.io/lambdasistemi/cardano-adversary`.

## Non-Functional Requirements

- **NFR-001** Resource budget: idle daemon < 50 MB RSS. (Real
  endpoints will revise this in their own specs.)
- **NFR-002** Cold-start time: from process exec to first
  `{"ready": true}` < 30 s on a warm devnet.
- **NFR-003** No stateful files in PR B. Endpoints that need
  persistence (any future replay/contention archetype) are out of
  scope.

## Out of Scope

- All Tier 1/2/3/4 misbehaviour archetypes other than the reserved
  `chain_sync_flap` slot. Each gets its own spec under
  `specs/0XX-...`.
- Topology variants where the adversary acts as a node-to-node
  *server* (Tier 3, upstream-peer Byzantine). Those need a separate
  testnet variant in `cardano-node-antithesis`.
- Compose wiring on the consumer side — that lives in
  [`cardano-foundation/cardano-node-antithesis#90`](https://github.com/cardano-foundation/cardano-node-antithesis/issues/90).

## Open Questions

- Whether the `chain_sync_flap` request schema should already match
  the final shape (so composer drivers don't need updating in PR C)
  or stay deliberately minimal here. **Decision proposed**: match
  the final shape now (seed, limit, n_conns), since the request
  fields are obvious from today's CLI args of the existing
  one-shot binary.

## References

- Wire spec: [`contracts/control-wire.md`](contracts/control-wire.md).
- Plan: [`plan.md`](plan.md).
- Tasks: [`tasks.md`](tasks.md).
- Antithesis-side roadmap: https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/docs/components/adversary-roadmap.md
- Antithesis-side tracking issue: https://github.com/cardano-foundation/cardano-node-antithesis/issues/89
