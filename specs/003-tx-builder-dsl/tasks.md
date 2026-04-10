# Tasks: Transaction Builder DSL

**Branch**: `003-tx-builder-dsl`
**Generated**: 2026-04-10
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Each task is a vertical slice: types + logic + test in one commit.

---

## US1: Script-spending transactions with typed redeemers

### Task 1.1: Core types and empty builder
**Story**: US1 | **Priority**: P1 | **Depends**: none

Define `TxBuilder`, `TxStep`, `SpendWitness`, `MintWitness` types and the `txBuilder` empty constructor in `Cardano.Node.Client.TxBuild`.

**Acceptance**: Module compiles, `txBuilder` returns an empty builder, types are exported.

**Commit scope**: `lib/Cardano/Node/Client/TxBuild.hs` (new file)

---

### Task 1.2: spend and spendScript combinators
**Story**: US1 | **Priority**: P1 | **Depends**: 1.1

Implement `spend` (pub-key) and `spendScript` (typed redeemer via existential `ToData`) combinators that append `Spend` steps to the builder.

**Acceptance**: Builder accumulates spend steps. Unit test: add two spends, verify step list contains both with correct witnesses.

**Commit scope**: `TxBuild.hs` + `test/Cardano/Node/Client/TxBuildSpec.hs` (new file)

---

### Task 1.3: draft — assemble without evaluation
**Story**: US1, US6 | **Priority**: P1 | **Depends**: 1.2

Implement `draft` that converts accumulated steps into a `Tx ConwayEra`:
- Collect all `Spend` steps into `inputsTxBodyL`
- Compute spending indices from sorted input set
- Build `Redeemers` map with `ConwaySpending (AsIx ix)` + placeholder ExUnits
- Attach scripts from builder's script map
- Compute script integrity hash

This is the assembly core without evaluation or balancing.

**Acceptance**: `draft` on a builder with `spendScript` produces a `Tx` with correct redeemer indices and integrity hash. Test with known inputs, verify index assignment matches `spendingIndex` from Internal.hs.

**Commit scope**: `lib/Cardano/Node/Client/TxBuild/Build.hs` (new file) + test

---

### Task 1.4: build — evaluate + patch + balance
**Story**: US1 | **Priority**: P1 | **Depends**: 1.3

Implement `build` that:
1. Calls `draft` to get the unbalanced tx
2. Evaluates scripts via Provider's `evaluateTx`
3. Patches ExUnits in redeemers
4. Recomputes script integrity hash
5. Calls existing `balanceTx`

This absorbs the entire `evaluateAndBalance` function from MPFS Internal.hs.

**Acceptance**: `build` with a mock Provider returning known ExUnits produces a balanced tx with patched redeemers. Integration test: build an End-shaped transaction, compare structure to hand-built version.

**Commit scope**: `Build.hs` + test

---

### Task 1.5: attachScript combinator
**Story**: US1 | **Priority**: P1 | **Depends**: 1.1

Implement `attachScript` that adds a script to the builder's script map (keyed by ScriptHash).

**Acceptance**: Attached scripts appear in `witsTxL . scriptTxWitsL` after `draft`.

**Commit scope**: `TxBuild.hs` + test

---

## US2: Minting/burning transactions

### Task 2.1: mint combinator
**Story**: US2 | **Priority**: P1 | **Depends**: 1.3

Implement `mint` combinator that appends `Mint` steps. `draft` must:
- Collect all Mint steps into `mintTxBodyL`
- Compute minting indices from sorted policy set
- Build `ConwayMinting (AsIx ix)` redeemer entries

Positive quantities mint, negative burn. Unified API following Scalus.

**Acceptance**: Builder with `spendScript` + `mint` produces a `Tx` with both spending and minting redeemers at correct indices. Test with Boot-shaped (mint +1) and End-shaped (mint -1 + spend) transactions.

**Commit scope**: `TxBuild.hs` + `Build.hs` + test

---

## US3: Typed inline datums

### Task 3.1: payTo and payTo' combinators
**Story**: US3 | **Priority**: P1 | **Depends**: 1.1

Implement `payTo` (address + value, no datum) and `payTo'` (address + value + typed datum with `ToData` constraint → inline datum). Also `output` for raw `TxOut` passthrough.

**Acceptance**: `payTo'` produces output with inline `Datum` constructed via `dataToBinaryData . Data . toPlcData`. Roundtrip test: encode datum, extract from TxOut, decode via `FromData`, compare.

**Commit scope**: `TxBuild.hs` + test

---

## US4: Reference inputs, validity, required signers

### Task 4.1: references, collaterals, validFrom, validTo, requireSignature
**Story**: US4 | **Priority**: P2 | **Depends**: 1.3

Implement remaining combinators:
- `references` → `referenceInputsTxBodyL`
- `collaterals` → `collateralInputsTxBodyL`
- `validFrom` → `ValidityInterval` lower bound
- `validTo` → `ValidityInterval` upper bound
- `requireSignature` / `requireSignatures` → `reqSignerHashesTxBodyL`

**Acceptance**: `draft` on a Retract-shaped builder (reference input + validity + required signer) has all fields set correctly. Unit tests for each combinator.

**Commit scope**: `TxBuild.hs` + `Build.hs` + test

---

## US5: Auto-complete

### Task 5.1: complete — query + select + build
**Story**: US5 | **Priority**: P2 | **Depends**: 1.4

Implement `complete` that:
1. Queries UTxOs from Provider at sponsor address
2. Selects inputs covering outputs + estimated fees (largest-first)
3. Adds collateral if any script steps present
4. Calls `build`

**Acceptance**: `complete` with a mock Provider returning known UTxOs produces a balanced tx. Error case: insufficient funds returns clear error.

**Commit scope**: `Build.hs` + test

---

## Conformance: Scalus test vectors

### Task 6.1: Extract Scalus test vectors
**Story**: Conformance | **Priority**: P2 | **Depends**: 1.4, 2.1

Extract test cases from Scalus TransactionBuilderTests.scala:
- Simple spend + payTo
- Script spend with redeemer
- Mint + spend combo
- Reference input + validity interval
- Multi-input with per-input redeemers

For each: capture builder steps, protocol params, UTxO set, and expected transaction CBOR or structure.

**Acceptance**: Test vectors documented as Haskell test cases. Our `build`/`draft` produces matching transaction structure.

**Commit scope**: `test/Cardano/Node/Client/TxBuild/ConformanceSpec.hs` (new file)

---

## Dependency Graph

```
1.1 ──→ 1.2 ──→ 1.3 ──→ 1.4 ──→ 5.1
  │               │        │
  ├──→ 1.5        ├──→ 2.1 ├──→ 6.1
  │               │
  ├──→ 3.1        └──→ 4.1
```

## Task Summary

| Task | Description | Priority | Depends |
|------|------------|----------|---------|
| 1.1  | Core types + empty builder | P1 | — |
| 1.2  | spend/spendScript combinators | P1 | 1.1 |
| 1.3  | draft (assembly without eval) | P1 | 1.2 |
| 1.4  | build (evaluate + patch + balance) | P1 | 1.3 |
| 1.5  | attachScript combinator | P1 | 1.1 |
| 2.1  | mint combinator (mint+burn) | P1 | 1.3 |
| 3.1  | payTo/payTo' with typed datums | P1 | 1.1 |
| 4.1  | references/collaterals/validity/signers | P2 | 1.3 |
| 5.1  | complete (auto-select + build) | P2 | 1.4 |
| 6.1  | Scalus conformance test vectors | P2 | 1.4, 2.1 |
