# Feature Specification: lib-block-indexer multi-handler refactor

**Feature Branch**: `feat/166-lib-block-indexer-multi-handler`  
**Created**: 2026-05-27  
**Status**: Draft  
**Input**: GitHub issue [#166](https://github.com/lambdasistemi/cardano-node-clients/issues/166)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Compose multiple block handlers (Priority: P1)

A downstream application wants one chain-sync subscription and one durable
transaction per block, while registering more than one indexing concern. One
handler keeps the live UTxO query surface available for arbitrary addresses;
another handler can maintain downstream-specific derived data with its own
filter. The application should not have to choose one global UTxO filter for
all concerns.

**Why this priority**: This is the structural blocker in #166. Without a
multi-handler block indexer, downstream consumers must either over-index
derived data with `IndexAll` or break live UTxO lookups with a small
interest set.

**Independent Test**: Run a unit test with the live UTxO handler plus a
trivial second handler. Apply one block and verify both handlers observe it
inside one block-indexer transaction; roll back and verify both handlers
receive rollback in a deterministic order.

**Acceptance Scenarios**:

1. **Given** two handlers are registered, **When** a non-EBB block rolls
   forward, **Then** both handlers apply under one block-level transaction.
2. **Given** both handlers produced inverse state for a followed block,
   **When** the chain rolls back past that block, **Then** rollback fans out
   to both handlers using the composite inverse for that block.
3. **Given** a handler can delete by slot range instead of storing inverse
   payloads, **When** rollback occurs, **Then** it can participate without
   adding a new UTxO-specific rollback column.

---

### User Story 2 - Existing UTxO indexer users see no behavior change (Priority: P1)

Existing users of `lib-utxo-indexer`, the bundled `utxo-indexer` executable,
and the caller-owned follower API continue to observe the same UTxO query,
await, persistence, replay, rollback, reconnect, and readiness behavior after
the refactor.

**Why this priority**: The issue is explicitly refactor-only. The new
abstraction is useful only if current consumers can upgrade without semantic
changes.

**Independent Test**: Run the existing unit and e2e suites unchanged, with
particular attention to `InterestSet` tests, replay-from-Origin idempotence,
Byron EBB skipping, restoration/following phase transition, RocksDB
persistence, and reconnect readiness.

**Acceptance Scenarios**:

1. **Given** the daemon runs with its current defaults, **When** it indexes a
   devnet chain, **Then** it behaves as if `InterestSet` were still `IndexAll`.
2. **Given** a caller uses `IndexAddressSet`, **When** a block contains creates
   both inside and outside the set, **Then** creates outside the set remain
   filtered while spends still pass exactly as today.
3. **Given** an existing RocksDB store, **When** the refactored indexer opens
   it, **Then** resume points, rollback history, query results, and await
   observations remain compatible.

---

### User Story 3 - Share readiness and lag-guard machinery (Priority: P2)

Downstream services should reuse a generic block-indexer readiness snapshot
and slot-lag guard instead of copying UTxO indexer follower boilerplate into
each application.

**Why this priority**: The same chain-follower wrapper and readiness bridge
is being repeated in downstream consumers. Moving it into the generic block
indexer keeps later downstream PRs small and focused on their own handlers.

**Independent Test**: The existing readiness and reconnect tests continue to
pass through the new generic readiness type, and focused unit tests prove the
lag guard computes ready/not-ready from processed slot, tip slot, upstream
status, and threshold without depending on UTxO-specific columns.

**Acceptance Scenarios**:

1. **Given** no block has rolled forward yet, **When** readiness is sampled,
   **Then** processed and tip slots remain unset as they do today.
2. **Given** the upstream disconnects, **When** readiness is sampled, **Then**
   the upstream status is preserved and consumers can derive not-ready.
3. **Given** processed slot and tip slot are both known, **When** lag is within
   the configured threshold, **Then** the generic lag guard reports ready.

### Edge Cases

- Byron EBBs must remain skipped before handler dispatch so same-slot Byron
  EBB/regular-block conflicts do not return.
- A handler failure during roll-forward must abort the whole block transaction;
  partial handler state for that block must not be committed.
- Rollback fanout must be deterministic and safe when some handlers recorded
  inverses and others use slot-range deletion.
- Restoration-phase sentinel rows must still avoid inverse computation for
  historical cold-sync blocks outside the stability window.
- Pruned rollback history must keep the existing replay-from-Origin behavior:
  already-finalized slots are skipped, not re-applied.
- Empty handler lists must be rejected or documented as a no-op before any
  consumer can accidentally run a chain-sync session that persists nothing.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The project MUST add a new public Cabal sublibrary backed by
  `lib-block-indexer/` for generic block-indexer concerns.
- **FR-002**: The new library MUST expose an `IndexerHandler cols inv`
  interface whose apply side receives block identity, block payload, and
  phase information, and whose rollback side receives the handler's inverse
  payload.
- **FR-003**: The block-indexer engine MUST compose multiple handlers into one
  chain-sync subscription and one block-level storage transaction.
- **FR-004**: The engine MUST own a composite inverse at the engine layer and
  fan rollback out to the registered handlers.
- **FR-005**: The current chain-follower `Runner.processBlock` phase dispatch,
  restoration sentinel behavior, rollback pruning, and RocksDB transaction
  shell MUST be factored out of `lib-utxo-indexer` into `lib-block-indexer`.
- **FR-006**: `lib-utxo-indexer` MUST expose
  `liveUtxoHandler :: InterestSet -> IndexerHandler Cols [UtxoOp]`.
- **FR-007**: `liveUtxoHandler` MUST preserve current `InterestSet` semantics
  exactly: `IndexAll` keeps every create, `IndexAddressSet` filters creates
  outside the set, and all spends pass through.
- **FR-008**: Current `lib-utxo-indexer` public query and await APIs MUST
  remain source-compatible unless a narrow compatibility shim is documented in
  the plan and covered by tests.
- **FR-009**: Generic readiness and slot-lag helpers MUST live in
  `lib-block-indexer` and MUST NOT depend on UTxO-specific columns, handlers,
  or query APIs.
- **FR-010**: The PR MUST NOT add tx-history or other derived columns.
- **FR-011**: The PR MUST NOT change `chain-follower` or alter the
  `chain-follower` source-repository-package pin except to preserve an already
  required build.
- **FR-012**: Existing unit and e2e tests MUST pass, and at least one new unit
  test MUST prove multi-handler composition with a trivial second handler.

### Key Entities

- **Block indexer engine**: Generic owner of chain-sync integration, phase
  dispatch, readiness, lag guard, rollback log handling, and transaction
  boundaries.
- **Indexer handler**: A consumer-specific block processor that contributes
  roll-forward effects and rollback behavior.
- **Composite inverse**: The engine-level rollback payload that records each
  handler's inverse contribution for one followed block.
- **Live UTxO handler**: The UTxO-specific handler that preserves current
  address index, tx-in index, observation, await, and rollback behavior.
- **Readiness snapshot**: Generic processed-slot, tip-slot, upstream-status,
  and update-time state used by daemons and embedded services to derive
  ready/not-ready.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `./gate.sh` passes at HEAD after all implementation slices.
- **SC-002**: Existing `InterestSet` unit tests pass without weakening any
  assertions.
- **SC-003**: Existing RocksDB persistence and rollback tests pass against data
  written before the refactor.
- **SC-004**: A new multi-handler unit test shows two handlers applying one
  block and rolling it back through one engine-managed composite inverse.
- **SC-005**: No new UTxO-derived columns such as transaction history appear in
  the PR diff.
- **SC-006**: Downstream consumers can continue to depend on
  `cardano-node-clients:utxo-indexer-lib` for the current query API while new
  consumers can additionally depend on the new block-indexer library.

## Assumptions

- The phase decision is already made by the parent orchestrator: this PR is
  refactor-only, and tx-history moves to a downstream PR.
- The new block-indexer library remains inside the existing Cabal package as a
  public sublibrary, matching the repo's current `utxo-indexer-lib` and
  `devnet` pattern.
- `BlockExtract` remains UTxO-specific unless implementation discovers a
  compelling reason to move only neutral block metadata helpers.
- The current `chain-follower` abstraction is sufficient and remains
  unchanged.
