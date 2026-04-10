# Feature Specification: Transaction Builder DSL

**Feature Branch**: `003-tx-builder-dsl`
**Created**: 2026-04-10
**Status**: Draft
**Input**: Transaction builder DSL inspired by Scalus for cardano-node-clients
**Issue**: lambdasistemi/cardano-node-clients#36

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build a script-spending transaction with typed redeemers (Priority: P1)

A dApp developer building Cardano transactions needs to spend script-protected UTxOs with typed redeemers, attach scripts, and get a balanced transaction with correct execution units — without manually computing redeemer indices, script integrity hashes, or iterating fee estimation.

**Why this priority**: This is the core value proposition. Every MPFS transaction builder (Boot, Update, End, Retract, Reject) performs script spends with redeemers. The manual index computation and integrity hash boilerplate is the primary pain point.

**Independent Test**: Can be tested by building a single script-spend transaction (e.g., the MPFS End transaction) and verifying it produces identical bytes to the current hand-built version.

**Acceptance Scenarios**:

1. **Given** a script UTxO, a typed redeemer value, and a Plutus script, **When** the developer uses `spendScript` + `attachScript` + `build`, **Then** the builder automatically computes the correct spending index, inserts placeholder ExUnits, evaluates the script, patches real ExUnits, computes the script integrity hash, and returns a balanced transaction.
2. **Given** multiple script inputs with different redeemers, **When** the developer adds them via multiple `spendScript` calls, **Then** each gets the correct index relative to the sorted input set.
3. **Given** a redeemer type with a `ToData` instance, **When** it is passed to `spendScript`, **Then** it is converted to ledger `Data` internally — the caller never touches raw data encoding.

---

### User Story 2 - Build a minting/burning transaction (Priority: P1)

A developer needs to mint or burn native tokens with a typed minting redeemer, combined with script spends in the same transaction.

**Why this priority**: Minting (Boot) and burning (End) are core MPFS operations. Both combine minting redeemers with spending redeemers in a single transaction.

**Independent Test**: Build the MPFS Boot transaction (mint +1 token) and End transaction (burn -1 token with dual spend+mint redeemers) using the DSL, verify against current output.

**Acceptance Scenarios**:

1. **Given** a policy ID, asset map, and typed minting redeemer, **When** the developer calls `mint`, **Then** the builder assigns the correct minting index and includes the minting redeemer in the witness set.
2. **Given** a transaction with both spending and minting redeemers, **When** `build` is called, **Then** the script integrity hash covers all redeemers correctly.
3. **Given** negative quantities in the asset map, **When** `mint` is called, **Then** tokens are burned (the builder does not distinguish mint from burn — sign of quantity determines it).

---

### User Story 3 - Pay to script address with typed inline datum (Priority: P1)

A developer needs to create outputs at script addresses with inline datums derived from typed Haskell values.

**Why this priority**: Every MPFS state and request output carries an inline datum. Currently requires manual encoding and lens setting.

**Independent Test**: Build an output with a typed datum, decode the inline datum from the resulting output, verify roundtrip.

**Acceptance Scenarios**:

1. **Given** a Haskell value with a `ToData` instance, **When** the developer pays to a script address with that datum, **Then** the output has the datum attached as an inline datum.
2. **Given** an output with a datum, **When** `build` produces the transaction, **Then** the datum is decodable back to the original type.

---

### User Story 4 - Reference inputs, validity intervals, required signers (Priority: P2)

A developer needs to add reference inputs (UTxOs read but not consumed), set time-based validity bounds, and require specific key signatures.

**Why this priority**: Used by Retract (reference input + validity interval + required signer) and Update (validity interval + required signer). Not as painful as redeemer mechanics but still boilerplate.

**Independent Test**: Build a Retract-shaped transaction with reference input, validity bounds, and required signer; verify all fields are set correctly in the resulting transaction body.

**Acceptance Scenarios**:

1. **Given** a UTxO reference, **When** `references` is called, **Then** it appears as a reference input, not a consumed input.
2. **Given** slot numbers, **When** `validFrom` and `validTo` are called, **Then** the validity interval has both bounds set.
3. **Given** a key hash, **When** `requireSignature` is called, **Then** it appears in the required signers set.

---

### User Story 5 - Complete: auto-select UTxOs and build (Priority: P2)

A developer wants to build a transaction without manually querying UTxOs and picking fee inputs — the builder should query the provider, select inputs to cover the outputs, add collateral if scripts are present, and balance.

**Why this priority**: Reduces boilerplate for the common case. Currently every builder manually queries wallet UTxOs, sorts by value, picks the largest.

**Independent Test**: Call `complete` with a provider and sponsor address, verify it produces a valid balanced transaction without the caller providing input UTxOs.

**Acceptance Scenarios**:

1. **Given** a provider and sponsor address, **When** `complete` is called, **Then** UTxOs are queried, sufficient inputs are selected, collateral is added if scripts are present, and the transaction is balanced.
2. **Given** insufficient funds at the sponsor address, **When** `complete` is called, **Then** a clear error is returned indicating the shortfall.

---

### User Story 6 - Draft: assemble without evaluation or balancing (Priority: P3)

A developer wants to inspect the transaction structure before committing to evaluation and balancing — useful for testing, debugging, and ScriptContext derivation.

**Why this priority**: Nice to have for development workflow. Not blocking any current functionality.

**Independent Test**: Call `draft`, inspect the resulting transaction, verify all steps are reflected without script evaluation or fee calculation.

**Acceptance Scenarios**:

1. **Given** a builder with steps, **When** `draft` is called, **Then** a transaction is returned with all inputs, outputs, mints, and witnesses set, but with zero fees and placeholder execution units.

---

### Edge Cases

- What happens when no script inputs exist but `attachScript` was called? Builder should still work — script is included but no redeemers needed.
- What happens when script evaluation fails? `build` should return the evaluation error with script logs, not a generic failure.
- What happens when balancing fails due to insufficient funds? Clear error with shortfall amount.
- What happens when the same input is added twice? Should be idempotent — sets deduplicate.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Builder MUST compute spending redeemer indices automatically from the sorted input set.
- **FR-002**: Builder MUST compute minting redeemer indices automatically from the sorted policy set.
- **FR-003**: Builder MUST compute the script integrity hash from protocol parameters and all redeemers.
- **FR-004**: Builder MUST evaluate scripts via the Provider and patch placeholder execution units with real values.
- **FR-005**: Builder MUST balance the transaction via the existing balance function after evaluation.
- **FR-006**: Builder MUST accept typed redeemers (`ToData` constraint) and convert them internally.
- **FR-007**: Builder MUST accept typed datums (`ToData` constraint) for inline datum outputs.
- **FR-008**: Builder MUST support all transaction components used by MPFS: script spends, minting, burning, reference inputs, collateral, validity intervals, required signers, inline datums.
- **FR-009**: `complete` MUST query UTxOs from the provider, perform input selection, and add collateral automatically.
- **FR-010**: `draft` MUST produce a transaction without evaluation or balancing.
- **FR-011**: Builder MUST work with ledger types directly — no cardano-api dependency.

### Key Entities

- **TxBuilder**: Immutable accumulator of transaction building steps.
- **TxStep**: Internal representation of a single building action (spend, send, mint, etc.).
- **SpendWitness**: How a spent input is authorized — pub-key or script with existential typed redeemer.
- **MintWitness**: How a minting operation is authorized — script with existential typed redeemer.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 7 MPFS transaction builders can be rewritten using the DSL with no change in on-chain behavior (identical transaction structure).
- **SC-002**: Each rewritten builder is at most 50% of the line count of the original.
- **SC-003**: The shared internal helpers for index computation, integrity hashing, and execution unit patching are no longer needed after migration.
- **SC-004**: All existing e2e tests pass without modification after the MPFS builders are migrated.
- **SC-005**: No new dependency on cardano-api is introduced.

## Conformance

Since this DSL replicates the Scalus TxBuilder architecture, we use Scalus test vectors for conformance:

- Extract transaction test cases from the Scalus test suite (TransactionBuilderTests.scala, TxBuilderTest.scala, TxBuilderCompleteTest.scala)
- For each test: capture the builder steps and the expected serialized transaction (CBOR bytes or equivalent)
- Our `build` function, given the same inputs and protocol parameters, must produce identical transaction structure
- Priority test vectors: script spend with redeemer, mint+spend combo, reference input + validity interval, multi-input with per-input redeemers

## Assumptions

- The existing balance function is sufficient for fee balancing — no changes needed.
- The existing Provider record (with evaluateTx, queryProtocolParams, queryUTxOs) provides everything `build` and `complete` need.
- All current transactions use PlutusV3 scripts only. The builder targets PlutusV3 initially (can be generalized later).
- Governance operations (votes, proposals, certificates) are out of scope — no current transaction uses them.
