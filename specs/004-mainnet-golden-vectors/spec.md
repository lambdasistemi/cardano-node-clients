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
2. Given a fixture that uses script spends, mints, or stake withdrawals, when the reconstruction runs, then the resulting transaction contains the same redeemer purposes, indices, and redeemer data.
3. Given the committed Conway-era sample, when unit tests run, then every fixture is exercised without external network access.

### User Story 2 - Keep the comparison aligned with current DSL guarantees

As a maintainer,
I want the conformance check to compare only the fields the current DSL intentionally controls,
so that failures point to real coverage gaps instead of unrelated balancing or witness details.

#### Acceptance Scenarios

1. Given a reconstructed transaction, when it is compared against the decoded mainnet transaction, then the test checks inputs, collateral, reference inputs, outputs, mint, withdrawals, validity interval, required signers, metadata, witness scripts, and redeemer data.
2. Given a reconstructed transaction, when the comparison runs, then fee amount, witness signatures, datum witnesses, ExUnits, and script integrity hash are excluded.

## Functional Requirements

- FR-001: The repository MUST include committed fixture files for the Conway-era transaction hashes used by the golden suite.
- FR-002: The unit test suite MUST decode each fixture into `Tx ConwayEra` using ledger decoding, not ad hoc parsing.
- FR-003: The test suite MUST reconstruct each transaction with `TxBuild` primitives supported today: spends, script spends, outputs, collateral, reference inputs, minting, withdrawals, required signers, validity interval, metadata, and attached witness scripts.
- FR-004: The test suite MUST compare the reconstructed transaction to the decoded fixture for the supported structural fields only.
- FR-005: The test suite MUST fail with a transaction-specific test name so regressions identify the affected protocol/hash quickly.
- FR-006: The golden tests MUST run offline from committed fixtures; they MUST NOT fetch Blockfrost data during CI.

## Key Entities

- Mainnet fixture: A committed CBOR-hex file keyed by the real transaction hash.
- Golden case: A named mapping from protocol label to transaction hash and fixture path.
- Supported structural equivalence: The subset of transaction structure intentionally controlled by the current TxBuild DSL.

## Success Criteria

- SC-001: Running the unit test suite exercises all committed Conway-era golden cases.
- SC-002: A regression in any covered TxBuild field produces a failing test for the specific affected transaction.
- SC-003: The tests pass without any external network dependency once fixtures are committed.
