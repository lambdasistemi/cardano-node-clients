# Feature Specification: Expand TxBuild Golden Vectors

**Feature Branch**: `feat/test-expand-txbuild-golden-vectors-with-new-protoc`
**Created**: 2026-04-12
**Status**: Draft
**Input**: GitHub issue `#46` "test: expand TxBuild golden vectors with new protocol families"

## User Scenarios & Testing

### User Story 1 - Broaden protocol-family coverage

As a maintainer of `cardano-node-clients`,
I want the Conway-era golden suite to cover additional documented protocol families,
so that the TxBuild DSL is checked against a wider slice of real mainnet traffic.

#### Acceptance Scenarios

1. Given the existing Conway-era golden harness, when new Splash, oracle, and Strike Finance fixtures are added, then each one passes the existing `draft` and offline `build` checks.
2. Given the expanded sample, when unit tests run, then every added vector still runs offline from committed fixtures only.

### User Story 2 - Keep vector selection defensible

As a maintainer,
I want each new fixture tied to a public protocol directory entry and a documented contract family,
so that the suite can justify why these transactions were selected.

#### Acceptance Scenarios

1. Given a selected Splash fixture, when its rationale is documented, then it links the transaction to the public Splash registry entry and to the Order Contract v3 script family.
2. Given a selected Strike Finance fixture, when its rationale is documented, then it links the transaction to the public Strike registry entry and to the Perps LP script family.
3. Given a selected oracle fixture, when its rationale is documented, then it links the transaction to the public Charli3 registry entry and to the Oracle v9 script family.

## Functional Requirements

- FR-001: The repository MUST add at least one new Conway-era Splash fixture that passes the existing `draft` and offline `build` golden checks.
- FR-002: The repository MUST add at least one new Conway-era oracle-oriented fixture that passes the existing `draft` and offline `build` golden checks.
- FR-003: The repository MUST add at least one new Conway-era Strike Finance fixture that passes the existing `draft` and offline `build` golden checks.
- FR-004: Each new fixture MUST include committed CBOR-hex and input-value files under the existing `test/fixtures/mainnet-txbuild/` layout.
- FR-005: The unit test suite MUST identify each new fixture with a protocol-specific test name.
- FR-006: The selection rationale MUST cite public Cardano ecosystem sources plus the public registry entry that names the contract family used for each selected transaction.

## Key Entities

- Splash order v3 vector: Transaction `a8de7b592e1ae77b92e1a2e21e41439c0721986f10f68a5126979aae4643d711`, selected from the public Splash registry entry because it consumes the documented Order Contract v3 address and passed the Conway-era golden harness.
- Strike perps LP vector: Transaction `cebc413826ebd61a4ee908617d668197dd1206ca39bb31429d538dc59fbb534f`, selected from the public Strike Finance registry entry because it consumes and recreates the documented Perps LP script address and passed the Conway-era golden harness.
- Charli3 oracle v9 vector: Transaction `46cb53fe682bc5189f76d4d91f2955bc2cb4bfbfca0689327495882bd10c8f50`, selected from the public Charli3 registry entry because it consumes and recreates the documented Oracle v9 script address and passed the Conway-era golden harness.

## Success Criteria

- SC-001: The unit test suite passes with the three added vectors included in the Conway-era sample.
- SC-002: The issue and PR both document why Splash, Strike Finance, and Charli3 were selected and which public registry entries anchor those choices.
- SC-003: The suite remains fully offline in CI after the new fixtures are committed.
