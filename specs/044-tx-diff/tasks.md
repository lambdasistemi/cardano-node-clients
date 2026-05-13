# Tasks: Conway Transaction Diff

**Input**: `specs/044-tx-diff/spec.md` and
`specs/044-tx-diff/plan.md`  
**Status**: Structural Conway body and opt-in witness traversal are
implemented. Blueprint handling has started with the parser subset.

## Phase 1: RED Tests

- [x] T001 [P] Add a unit test proving equal roots stop traversal before any
  child access.
- [x] T002 [P] Add a unit test for one Conway fee change producing one changed
  fee path.
- [x] T003 [P] Add a unit test for one output coin change preserving only the
  needed output context.
- [x] T004 [P] Add a unit test for map factoring into `common`, `changed`,
  `onlyA`, and `onlyB`.
- [x] T005 [P] Add a unit test for nested map factoring with equality stops at
  equal inner values.
- [x] T006 [P] Add a unit test for deterministic sequence alignment by index
  when no stable key exists.
- [ ] T007 [P] Add a unit test for matched blueprint datum/redeemer traversal
  into an open application value.
- [x] T008 [P] Add unit tests for missing and ambiguous blueprint fallback.
- [x] T032 [P] Add QuickCheck properties for equality stopping, object
  partitioning, array alignment, and scalar changed leaves.

## Phase 2: Diff Model

- [x] T009 Define the internal `DiffNode` model and path representation.
- [x] T010 Implement the equality-first diff combinator over a small test
  fixture type.
- [x] T011 Implement render-independent collection of `same`, `changed`,
  `onlyA`, `onlyB`, and parent nodes.
- [x] T012 Implement map factoring with recursive changed children.
- [x] T013 Implement deterministic sequence alignment and tail
  insertion/deletion reporting.

## Phase 3: Conway Traversal

- [x] T014 Add the finite Conway transaction traversal table.
- [x] T015 Add transaction body traversal for fee, validity interval, inputs,
  reference inputs, collateral inputs, outputs, mint, withdrawals, required
  signers, and total collateral.
- [x] T033 Add the first Conway body traversal leaf: `body.fee`.
- [x] T034 Add Conway body traversal for `body.validityInterval`.
- [x] T035 Add Conway body traversal for `body.outputs[*].coin`.
- [x] T036 Add Conway output traversal for `body.outputs[*].address`.
- [x] T037 Add Conway output traversal for `body.outputs[*].datum`.
- [x] T038 Add Conway output traversal for
  `body.outputs[*].referenceScript`.
- [x] T039 Add Conway body traversal for `body.inputs`.
- [x] T040 Add Conway body traversal for `body.referenceInputs`.
- [x] T041 Add Conway body traversal for `body.collateralInputs`.
- [x] T042 Add Conway body traversal for `body.totalCollateral`.
- [x] T043 Add Conway body traversal for `body.requiredSigners`.
- [x] T044 Add Conway body traversal for `body.withdrawals`.
- [x] T045 Add Conway body traversal for `body.mint`.
- [x] T016 Add output traversal with address, value/coin, datum, and script
  leaves where exposed by the ledger API.
- [x] T017 Add opt-in witness traversal.
- [x] T046 Add opt-in witness traversal for witness scripts.
- [x] T047 Add opt-in witness traversal for datum values.
- [x] T048 Add opt-in witness traversal for redeemer data and execution units.
- [x] T049 Add opt-in witness traversal for verification key witnesses.
- [x] T050 Add opt-in witness traversal for bootstrap witnesses.
- [x] T018 Keep unknown unequal ledger values atomic at their current path.

## Phase 4: Blueprint Boundary

- [x] T019 Parse the required Plutus blueprint subset.
- [x] T020 Match blueprints at datum/redeemer leaves using available
  validator context.
- [x] T021 Convert matched Plutus data into the open application value tree.
- [x] T022 Apply the same equality-first diff to open application values.
- [x] T023 Report missing and ambiguous blueprint matches explicitly.

## Phase 5: Rendering And CLI

- [x] T024 Add a human renderer over `DiffNode`.
- [x] T025 Add exact numeric rendering for known ledger scalar units.
- [x] T026 Add input decoding for CBOR hex, raw CBOR, and cardano-cli JSON
  envelope inputs.
- [x] T027 Add the thin `tx-diff` executable.
- [x] T028 Wire the executable into cabal and Nix only after the library tests
  are passing.

## Phase 6: Verification

- [x] T029 Run the focused TxDiff unit tests.
- [x] T030 Run `just unit`.
- [ ] T031 Regenerate any gist/output artifacts only from the executable,
  after the executable exists again.
