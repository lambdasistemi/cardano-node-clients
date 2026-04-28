# Feature Specification: Cardano TX Generator (Antithesis-driven, growing-population fan-out)

**Feature Branch**: `034-cardano-tx-generator`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "Long-running Cardano transaction-generator daemon driven by the Antithesis composer; creates monotonic UTxO and address pressure on a node by submitting fan-out transactions to a growing population of deterministically-derived addresses; deterministic given a seed; uses the in-tree TxBuild DSL to build transactions, the in-tree address-to-UTxO indexer library to track UTxOs, and a single node-to-client (N2C) connection to the relay for both chain-sync and local-tx-submission."

## User Scenarios & Testing *(mandatory)*

The primary user is the **Antithesis test composer**, which fires
short trigger commands at the daemon at random intervals during a
test run. A secondary user is the **operator** who wires the daemon
into the Antithesis testnet's compose stack and reads its diagnostic
output. Each user journey below is independently testable: removing
any later journey still leaves a daemon that delivers value to the
composer.

### User Story 1 - Trigger one transaction (Priority: P1)

The composer fires a trigger command supplying a fresh random seed.
The daemon picks one source address from its growing population
using that seed, builds a single transaction that consumes one of
that address's UTxOs and produces K outputs (each at a
randomly-drawn viable value, some sent to fresh population
addresses, some to existing population members) plus a change output
back to the source, submits the transaction, waits for the change
output to be observed, and answers with the transaction ID and the
chosen destinations.

**Why this priority**: This is the core value loop. Without it the
daemon contributes no pressure to the test. Every other story builds
on this one's contract.

**Independent Test**: Stand up the daemon against a devnet, send 100
trigger commands with distinct seeds, and verify (a) that 100
transactions land on chain, (b) that the population size grew by the
expected lower bound, and (c) that the total UTxO count at
population addresses grew by 100 · K.

**Acceptance Scenarios**:

1. **Given** the daemon is running, the embedded address-to-UTxO
   index is in sync with the relay's tip, and the population has at
   least one address with a UTxO that supports K outputs at the
   protocol's minimum threshold, **When** the composer sends a
   trigger command with seed `s` and parameters K and prob_fresh,
   **Then** the daemon submits exactly one transaction, waits for
   the change UTxO to be observed by its embedded index within the
   configured timeout, and responds with the resulting transaction
   ID, the K destinations used, the values placed at each
   destination, and confirmation that the await landed within the
   timeout.

2. **Given** the daemon has just restarted and re-read its persisted
   state, **When** the composer sends a trigger command with the
   same seed as a previous successful run, the same on-chain
   starting state, and the same parameters, **Then** the daemon
   submits a transaction with byte-identical body to the previous
   run.

3. **Given** no address in the current population has a UTxO that
   meets the viability floor for the requested K, **When** the
   composer sends a trigger command, **Then** the daemon answers
   with a "not-applicable" response (without submitting a
   transaction) so the composer records the tick as skipped instead
   of failing the test.

---

### User Story 2 - Refill from faucet (Priority: P2)

The composer fires a separate refill command supplying a fresh
random seed. The daemon pulls value from a configured faucet
address into a freshly-derived population address. Bootstrap (the
very first move that seeds the population from the faucet) uses the
same command path. The refill is also deterministic given the seed
and the faucet's UTxO state.

**Why this priority**: Without this arm, the population eventually
runs out of viable sources and Story 1 stops landing. With it, the
faucet's holdings become the natural rate-limiter for the run.

**Independent Test**: With Story 1's loop disabled, fire a single
refill command and verify the population grew by exactly one fresh
address with a non-zero UTxO, and the embedded index reports the
faucet's balance decreased by the expected amount.

**Acceptance Scenarios**:

1. **Given** the population is empty (cold start) and the faucet
   address holds value, **When** the composer sends a refill
   command with seed `s`, **Then** the daemon derives a new
   population address, builds a transaction that pays from the
   faucet to that address, submits it, awaits the new UTxO at the
   population address, and responds with the transaction ID and the
   new address index.

2. **Given** the embedded index has not yet caught up to the blocks
   that contain the faucet's UTxOs, **When** the composer sends a
   refill command, **Then** the daemon answers with a
   "not-applicable" response indicating the faucet is not yet
   known, instead of submitting a transaction.

---

### User Story 3 - Snapshot for validators (Priority: P2)

The composer's eventually- and finally-validators query the daemon
for an aggregate view: how big is the population, what does the
UTxO value distribution look like at population addresses, what
slot is the embedded index at, and what was the last transaction
the daemon submitted. The query is read-only and never blocks on
submission or chain progress.

**Why this priority**: Without this, the composer can only assert
"the daemon answered without error" — not "pressure is actually
landing on the node." The validators need to read the curve to
score the run.

**Independent Test**: Send a snapshot query before any trigger,
then fire N triggers, then send another snapshot query; assert that
the population size grew by at least the expected lower bound and
that the value-distribution percentiles drifted downward.

**Acceptance Scenarios**:

1. **Given** the daemon has been running for some time and has
   processed several trigger commands, **When** the composer sends
   a snapshot query, **Then** the daemon answers with the current
   population size, the p10/p50/p90 of UTxO values held at
   population addresses, the embedded index's current tip slot, and
   the transaction ID of the last submitted transaction (or none if
   no transactions have been submitted yet).

2. **Given** a long-running test, **When** the validator subtracts
   a startup-time snapshot from a near-end snapshot, **Then** the
   delta in population size is non-negative and the delta in median
   UTxO value is non-positive.

---

### User Story 4 - Readiness probe (Priority: P3)

The compose-stack healthcheck and the composer's startup phase
need a cheap way to know when the daemon is ready to accept
triggers without producing spurious "not-applicable" responses.

**Why this priority**: Necessary for clean compose-orchestration
but not load-bearing for the test signal itself.

**Independent Test**: Bring the daemon up before the relay is
reachable; verify the readiness probe reports "not ready, index not
ready"; bring the relay up; verify the readiness probe transitions
to "ready" within bounded time after the index reaches the relay's
tip.

**Acceptance Scenarios**:

1. **Given** the relay socket is reachable but the embedded index
   is still bootstrapping, **When** the composer sends a readiness
   probe, **Then** the daemon answers `{ready: false, indexReady:
   false, faucetUtxosKnown: <bool>}` without blocking.

2. **Given** the embedded index is in sync with the relay's tip and
   the faucet's UTxOs are known to it, **When** the composer sends
   a readiness probe, **Then** the daemon answers `{ready: true,
   indexReady: true, faucetUtxosKnown: true}`.

---

### Edge Cases

- **Submission rejected by the node** (e.g. ledger validation
  failure): the daemon responds with a `submit-rejected` error
  carrying the ledger's reason text. The transaction is not
  retried; the composer treats this tick as a failed driver
  invocation. The persisted state is not advanced for the failed
  transaction.
- **`await` timeout**: the daemon submitted the transaction but
  the embedded index has not yet observed the change UTxO within
  the configured bound. The response indicates the timeout,
  includes the submitted transaction ID, and is *not* an error
  from the composer's perspective — the next snapshot will reveal
  whether the transaction landed or got rolled back.
- **Daemon restart mid-run**: the daemon resumes operation by
  re-reading the persisted next-HD-index and the master seed from
  disk, then re-attaching to the relay's N2C socket and rebuilding
  the in-process index from a saved checkpoint per the indexer
  library's existing recovery contract. Addresses are derived on
  demand by index; the existing population is not eagerly
  re-derived.
- **Single N2C connection drops**: chain-sync, local-tx-submission,
  and the embedded index all share one N2C connection to the relay.
  If that connection drops, all three are unavailable and the
  daemon transitions to "not ready" until reconnection. The
  composer's readiness probe surfaces this state.
- **Duplicate seed received**: not a special case. The daemon
  re-executes the request with that seed; given the same on-chain
  state, the result is identical (and the resulting transaction is
  rejected by the node as a duplicate, which is reported as
  `submit-rejected`).
- **All sources fragmented to dust**: the source-pick floor cannot
  be satisfied for any population member. Successive trigger
  commands return "not-applicable" until the composer fires a
  refill command; refills inject fresh value into a new population
  address and Story 1 resumes.
- **Faucet exhausted**: a refill command receives an explicit
  `faucet-exhausted` response. The composer's tick records this as
  the natural end-of-test condition.
- **Concurrent control connections**: if two composer commands
  fire at exactly the same time, the daemon serialises them so
  that each observes the other's effect on the persisted
  next-HD-index; transactions submitted by both carry distinct
  sources and distinct fresh-destination indices.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The daemon MUST accept exactly one external trigger
  per request and submit at most one transaction per trigger.
  There is no internal scheduler, no retry loop, and no in-process
  pacing — every transaction the daemon submits is the direct
  consequence of one external request.

- **FR-002**: The daemon MUST derive all per-request randomness
  (source pick, destination picks, fresh-vs-existing coin flips,
  per-output value sampling) exclusively from the seed in the
  request payload. The daemon MUST NOT consult the system clock,
  `/dev/urandom`, environment-supplied randomness, or any other
  ambient source on the transaction-construction path.

- **FR-003**: The daemon MUST persist the next-HD-index across
  restarts so the population it owns can be re-derived
  deterministically and so a restart does not collide with
  previously used addresses.

- **FR-004**: The address population MUST grow monotonically
  across the lifetime of a run; an address that has been derived
  once is never retired or re-numbered.

- **FR-005**: A successful trigger response MUST grow the count of
  UTxOs at population addresses by the K supplied in the request
  (one input is consumed and replaced by K destination outputs
  plus one change output back to the source, netting +K).

- **FR-006**: When no population address has a UTxO that supports
  K outputs at the protocol's minimum-UTxO threshold plus the fee,
  the daemon MUST answer with a "not-applicable" response without
  submitting a transaction, in a form the composer can recognise
  as "skip this tick" rather than "test failed."

- **FR-007**: The daemon MUST track UTxOs at population addresses
  by embedding the in-tree address-to-UTxO indexer library in its
  own process. It MUST NOT consume an external indexer over IPC
  and it MUST NOT shell out to the node's local-state-query
  channel for these reads.

- **FR-008**: The daemon MUST open exactly one node-to-client
  (N2C) connection to the configured relay socket at startup and
  use that single connection for both chain-sync (which feeds the
  embedded index) and local-tx-submission (which writes
  transactions). It MUST NOT open separate connections per
  protocol.

- **FR-009**: The daemon MUST construct transaction bodies using
  the in-tree TxBuild DSL (with its existing `BalanceResult` and
  ref-script-fee handling), not a hand-rolled balancer.

- **FR-010**: After submitting a transaction, the daemon MUST
  wait, with a configurable bounded timeout, for the embedded
  index to observe the transaction's change UTxO before
  responding. The response MUST indicate whether the await landed
  within the timeout.

- **FR-011**: The daemon MUST expose a read-only snapshot query
  returning at minimum: current population size, percentiles of
  the UTxO value distribution at population addresses, embedded
  index tip slot, and the transaction ID of the most recently
  submitted transaction (or a null value if none has been
  submitted yet).

- **FR-012**: The daemon MUST expose a readiness query reporting
  whether the embedded index is ready and whether the faucet's
  UTxOs are known to it. Neither query MUST mutate state nor block
  on chain progress.

- **FR-013**: The daemon MUST expose a refill arm that, on
  external trigger with a seed, derives a fresh population address
  and pays from the configured faucet to it. This arm MUST be
  deterministic in the same sense as the transact arm and MUST
  persist the next-HD-index across the operation.

- **FR-014**: A successful trigger response MUST carry the
  submitted transaction's ID, the chosen source address index, the
  chosen destination address indices, the value placed at each
  destination, and the await result.

- **FR-015**: An unsuccessful response MUST carry a discriminable
  reason category (`no-pickable-source`, `index-not-ready`,
  `faucet-exhausted`, or `submit-rejected:<ledger-reason>`) so
  composer scripts can decide between "skip", "retry", "report
  ledger reason", and "end of test."

- **FR-016**: Two trigger requests MUST NOT race on the persisted
  next-HD-index; the daemon MUST serialise externally-triggered
  state mutations so that the persisted state and the on-chain
  effect agree on the ordering.

### Key Entities

- **Population**: the monotonically growing set of addresses ever
  derived from the master seed by the daemon. Identified by HD
  index. Each address is owned by the daemon (the daemon holds
  the signing key).
- **Embedded address-to-UTxO index**: an in-process address-keyed
  view of the chain's UTxO set at population addresses (and the
  faucet), maintained by chain-syncing the relay over the daemon's
  single N2C connection.
- **Source UTxO**: a UTxO observed by the embedded index at a
  population address whose value supports K destination outputs at
  the protocol minimum plus the transaction fee.
- **Transact request**: an externally supplied seed plus K and
  prob_fresh, identifying one tick at which the daemon should fan
  out one source UTxO into K + 1 outputs.
- **Refill request**: an externally supplied seed identifying one
  tick at which the daemon should pay from the faucet to a fresh
  population address.
- **Snapshot**: a read-only aggregate view of population size,
  UTxO value distribution percentiles, embedded index tip slot,
  and the last submitted transaction ID.
- **Faucet**: an address external to the population that holds
  the initial value from which refills draw. Its keys and address
  are configuration; the daemon does not control how it is funded.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100 sequential transact requests with distinct
  seeds, fired against a devnet with a sufficiently funded faucet
  and a freshly-bootstrapped population, produce 100 confirmed
  transactions and grow the embedded-index-observed population
  size by at least `100 · K · prob_fresh − 5` (small variance for
  randomness).

- **SC-002**: Replaying the same seed sequence against an
  identical starting on-chain state produces an identical
  sequence of submitted transaction IDs. Bit-identical, modulo
  nothing.

- **SC-003**: A snapshot of any population address taken from the
  daemon's embedded index matches the node's authoritative UTxO
  view at that address byte-for-byte (this property is inherited
  from the indexer library's contract; the daemon does not
  corrupt it).

- **SC-004**: When the source-pick viability floor cannot be
  satisfied for any population member, the "not-applicable"
  response is delivered within one second of the request arriving,
  so the composer's tick budget is not consumed by long timeouts.

- **SC-005**: Mean UTxO value at population addresses drifts
  monotonically downward toward the protocol's minimum-UTxO
  threshold over the course of a sustained run, observable through
  successive snapshot queries — that is, fragmentation is
  sustained, not just an artifact of the first few transactions.

- **SC-006**: A daemon restart between transact request `n` and
  transact request `n + 1` produces no observable difference in
  the outcome of request `n + 1`: same transaction ID, same
  destinations, same values, modulo any rolled-back blocks the
  embedded index reports through its standard contract.

- **SC-007**: Across an Antithesis test run of three hours at the
  default composer cadence, the population size as observed via
  successive snapshot queries strictly increases (modulo restarts
  and rollbacks, which are recoverable per SC-006), and no "All
  commands were run to completion at least once" composer finding
  is raised against the trigger commands.

## Assumptions

- The Antithesis composer scripts in the consumer testnet
  repository obtain randomness from the Antithesis SDK's
  randomness primitive (which the harness varies across runs) and
  pass it to the daemon as the request's seed. The daemon does
  not depend on which SDK or language the composer uses; it
  accepts seeds as inputs to its control protocol.
- The merged in-tree address-to-UTxO indexer is consumed as a
  **library** in this daemon's own process. The separately-built
  indexer **executable** is not consumed by this daemon.
- The daemon owns its single N2C connection to the relay. The
  relay's N2C socket is the only upstream interface the daemon
  uses; it does not hold a side channel for queries.
- A single configured faucet address holds enough lovelace to
  sustain refills for the duration of an Antithesis run. Sizing
  the faucet is the testnet operator's responsibility, not the
  daemon's; the daemon reports `faucet-exhausted` when the faucet
  runs dry, and that is the natural end-of-test condition.
- Transaction fees and minimum-UTxO thresholds are read from the
  node's protocol parameters (or configured), not hardcoded;
  network/era changes that change those parameters are absorbed
  through the existing TxBuild DSL.
- Multi-asset, datum, and reference-script payloads are out of
  scope for this feature. Pressure axes beyond pure-ADA fan-out
  are separate features that can layer onto this daemon's
  architecture without changing its control contract.
- One relay socket is targeted per process. Submitting to
  multiple relays simultaneously is out of scope; a multi-relay
  deployment runs multiple daemon instances against multiple
  relays.
- The daemon runs as a long-lived process under a process
  supervisor (for example a container orchestrator's restart
  policy); ungraceful termination is recoverable from the
  persisted state per SC-006.
