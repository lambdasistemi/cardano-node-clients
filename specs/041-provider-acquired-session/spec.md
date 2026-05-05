# Feature Specification: Provider acquired query session

**Feature Branch**: `feat/provider-single-acquire-multi-query-session-for-at`
**Created**: 2026-05-05
**Status**: Implemented
**Input**: Issue [#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126) - expose a bracket-shaped provider API so downstream registry walks can run several ledger queries against one LocalStateQuery acquired snapshot.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Registry walk reads one consistent snapshot (Priority: P1)

A downstream tool opens an acquired provider session, reads registry datums by address, then reads the referenced script UTxOs by `TxIn`. All reads come from the same chain point, so the tool can distinguish a real redeploy from chain-tip jitter.

**Why this priority**: This is the issue's main value. Without it, consumers that need related UTxOs must compose multiple one-shot provider calls, each with its own acquire/release cycle.

**Independent Test**: In an E2E devnet test, call the new acquired API and run at least three query methods in a single bracket. The test must use the same `QueryHandle` for protocol parameters, address UTxOs, and TxIn lookup.

**Acceptance Scenarios**:

1. **Given** an N2C-backed provider, **When** a caller runs `withAcquired provider`, **Then** the callback receives a handle that can perform multiple provider-style queries before the LSQ client releases.
2. **Given** a handle from `withAcquired`, **When** the caller queries one address and then looks up a `TxIn` returned by that query, **Then** the lookup sees the same output in the same acquired session.
3. **Given** a caller uses existing one-shot methods, **When** they call `queryUTxOs`, `queryUTxOByTxIn`, or `queryProtocolParams`, **Then** those calls still work without call-site changes.

### User Story 2 - Existing provider consumers keep their API shape (Priority: P1)

Existing downstream tools that only need one-shot queries continue to call the same `Provider` fields. The N2C implementation internally uses the acquired machinery for those calls, but consumers do not have to opt in.

**Why this priority**: The feature is for new atomic reads. It must not force unrelated tools to rewrite basic provider usage.

**Independent Test**: Run the existing unit and E2E suites unchanged, including current `Provider.N2C`, tx-build, balancer, and tx-generator tests.

**Acceptance Scenarios**:

1. **Given** existing code calling `queryProtocolParams provider`, **When** it is rebuilt, **Then** it compiles and behaves as before.
2. **Given** existing code calling `queryUTxOs provider addr`, **When** it is rebuilt, **Then** it still returns the UTxOs at that address.
3. **Given** existing code calling `evaluateTx` or POSIX-to-slot helpers, **When** it is rebuilt, **Then** those LSQ-backed helpers still return their current results.

### Edge Cases

- The user callback throws an exception: the acquired LSQ session must release before the exception escapes.
- The N2C bearer dies while a caller is waiting for acquisition or query results: callers should receive the existing typed `ConnectionLost` signal rather than block indefinitely.
- A `QueryHandle` is leaked outside its callback: this is caller misuse; the API keeps the constructor opaque to discourage it.
- Multiple ordinary `queryLSQ` callers may still queue work concurrently; preserving the existing opportunistic batch behavior is allowed but not required for the new bracket semantics.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `Cardano.Node.Client.Provider` MUST expose an opaque `QueryHandle m` type.
- **FR-002**: `Provider m` MUST expose `withAcquired :: (QueryHandle m -> m a) -> m a`.
- **FR-003**: `QueryHandle m` MUST expose acquired-session forms for all existing LSQ-backed provider operations: UTxO-by-address, UTxO-by-TxIn, protocol parameters, transaction evaluation, floor POSIX-to-slot, and ceiling POSIX-to-slot.
- **FR-004**: The acquired address query MUST support querying a set of addresses and return results grouped by address.
- **FR-005**: The N2C implementation MUST acquire LocalStateQuery once, serve all handle queries from that callback, and release after the callback exits.
- **FR-006**: The N2C one-shot provider fields MUST delegate through `withAcquired` so each one-shot call still performs exactly one bracketed acquire/release cycle.
- **FR-007**: `queryLSQ` MUST remain available for existing low-level callers.
- **FR-008**: A dead LSQ consumer while waiting for acquisition, query, or release MUST surface as `ConnectionLost`.
- **FR-009**: Existing downstream one-shot call sites MUST remain unchanged.

### Key Entities

- **Provider**: Public record-of-functions for ledger queries. Gains `withAcquired` while retaining current one-shot fields.
- **QueryHandle**: Opaque high-level handle passed only inside an acquired callback.
- **Acquired LSQ session**: Lower-level LocalStateQuery state that owns a queue of queries served before release.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An E2E devnet test executes at least three provider queries through one `QueryHandle` and passes.
- **SC-002**: Existing one-shot provider E2E tests continue to pass with no caller changes.
- **SC-003**: `nix develop --quiet -c just ci` passes after the change.
- **SC-004**: The public docs show both one-shot and acquired-session usage.

## Assumptions

- This feature does not change the LSQ wire codec or add a multi-query wire message.
- `Provider` remains a record-of-functions, matching the current public API style.
- Query consistency is scoped to one LocalStateQuery `Acquire` on the volatile tip.

## Out of Scope

- Cross-acquire batching.
- Changing transaction submission or chain-sync APIs.
- Adding application-specific registry-walk helpers.
