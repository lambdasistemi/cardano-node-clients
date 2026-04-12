# Feature Specification: Mainnet TxBuild Golden Vectors

**Feature Branch**: `feat/txbuild-golden-tests-against-12-mainnet-transactio`
**Created**: 2026-04-12
**Status**: Draft
**Input**: GitHub issue `#43` "TxBuild: golden tests against 12 mainnet transactions from 10 protocols"

## User Scenarios & Testing

### User Story 1 - Prove TxBuild covers real mainnet transaction structure

As a maintainer of `cardano-node-clients`,
I want a committed set of real mainnet transaction vectors,
so that the TxBuild DSL is checked against the structures production protocols actually submit.

#### Acceptance Scenarios

1. Given a committed mainnet fixture, when the test suite decodes it into `Tx ConwayEra`, then the test can reconstruct the same supported structure with `TxBuild`.
2. Given a committed input-value fixture for the same transaction, when the suite runs `build` with replayed original `ExUnits`, then balancing succeeds without external network access.
3. Given a fixture that uses script spends, mints, or stake withdrawals, when the reconstruction runs, then the resulting transaction contains the same redeemer purposes, indices, redeemer data, and replayed `ExUnits`.
4. Given the committed Conway-era sample, when unit tests run, then every fixture is exercised without external network access.

### User Story 2 - Keep the comparison aligned with current DSL guarantees

As a maintainer,
I want the conformance check to compare only the fields the current DSL intentionally controls,
so that failures point to real coverage gaps instead of unrelated balancing or witness details.

#### Acceptance Scenarios

1. Given a drafted transaction, when it is compared against the decoded mainnet transaction, then the test checks inputs, collateral, reference inputs, outputs, mint, withdrawals, validity interval, required signers, metadata, witness scripts, and redeemer data.
2. Given a built transaction, when it is compared against the decoded mainnet transaction, then the test checks the same fields plus replayed `ExUnits`, while allowing one appended change output and a recomputed fee.
3. Given a reconstructed transaction, when the comparison runs, then witness signatures, datum witnesses, and script integrity hash are excluded.

## Functional Requirements

- FR-001: The repository MUST include committed fixture files for the Conway-era transaction hashes used by the golden suite.
- FR-002: The repository MUST include committed offline input-value fixtures for the non-reference, non-collateral inputs consumed by each golden transaction.
- FR-003: The unit test suite MUST decode each fixture into `Tx ConwayEra` using ledger decoding, not ad hoc parsing.
- FR-004: The unit test suite MUST reconstruct each transaction with `TxBuild` primitives supported today: spends, script spends, outputs, collateral, reference inputs, minting, withdrawals, required signers, validity interval, metadata, and attached witness scripts.
- FR-004: The golden suite MUST run both a `draft` conformance pass and a `build` pass that balances against the committed input-value fixtures.
- FR-005: The golden suite MUST run both a `draft` conformance pass and a `build` pass that balances against the committed input-value fixtures.
- FR-006: The `build` pass MUST replay the original redeemer `ExUnits` from the decoded transaction instead of relying on live chain evaluation.
- FR-007: The test suite MUST compare the reconstructed transactions to the decoded fixtures only for the supported structural fields.
- FR-008: The `build` pass MUST allow exactly one appended change output and a recomputed fee.
- FR-009: The test suite MUST fail with a transaction-specific test name so regressions identify the affected protocol/hash quickly.
- FR-010: The golden tests MUST run offline from committed fixtures; they MUST NOT fetch Blockfrost data during CI.

## Key Entities

- Mainnet fixture: A committed CBOR-hex file keyed by the real transaction hash.
- Input-value fixture: A committed file keyed by the golden transaction hash that lists the lovelace value of each consumed non-reference, non-collateral input.
- Golden case: A named mapping from protocol label to transaction hash and fixture path.
- Supported structural equivalence: The subset of transaction structure intentionally controlled by the current TxBuild DSL, plus replayed `ExUnits` in the `build` phase.

## Success Criteria

- SC-001: Running the unit test suite exercises all committed Conway-era golden cases.
- SC-002: A regression in any covered TxBuild field produces a failing test for the specific affected transaction.
- SC-003: The tests pass without any external network dependency once fixtures are committed.
