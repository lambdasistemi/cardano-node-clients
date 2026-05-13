# Tasks: Conway Transaction Diff

**Input**: `specs/044-tx-diff/spec.md` and
`specs/044-tx-diff/plan.md`  
**Status**: First structural diff slice is implemented. Conway body traversal
is proceeding field by field; blueprint handling has not started.

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
- [ ] T008 [P] Add unit tests for missing and ambiguous blueprint fallback.
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
- [ ] T015 Add transaction body traversal for fee, validity interval, inputs,
  reference inputs, collateral inputs, outputs, mint, withdrawals, required
  signers, and total collateral.
- [x] T033 Add the first Conway body traversal leaf: `body.fee`.
- [x] T034 Add Conway body traversal for `body.validityInterval`.
- [x] T035 Add Conway body traversal for `body.outputs[*].coin`.
- [x] T036 Add Conway output traversal for `body.outputs[*].address`.
- [x] T037 Add Conway output traversal for `body.outputs[*].datum`.
- [x] T038 Add Conway output traversal for
  `body.outputs[*].referenceScript`.
- [ ] T016 Add output traversal with address, value/coin, datum, and script
  leaves where exposed by the ledger API.
- [ ] T017 Add opt-in witness traversal.
- [ ] T018 Keep unknown unequal ledger values atomic at their current path.

## Phase 4: Blueprint Boundary

- [ ] T019 Parse the required Plutus blueprint subset.
- [ ] T020 Match blueprints at datum/redeemer leaves using available
  validator context.
- [ ] T021 Convert matched Plutus data into the open application value tree.
- [ ] T022 Apply the same equality-first diff to open application values.
- [ ] T023 Report missing and ambiguous blueprint matches explicitly.

## Phase 5: Rendering And CLI

- [ ] T024 Add a human renderer over `DiffNode`.
- [ ] T025 Add exact numeric rendering for known ledger scalar units.
- [ ] T026 Add input decoding for CBOR hex, raw CBOR, and cardano-cli JSON
  envelope inputs.
- [ ] T027 Add the thin `tx-diff` executable.
- [ ] T028 Wire the executable into cabal and Nix only after the library tests
  are passing.

## Phase 6: Verification

- [x] T029 Run the focused TxDiff unit tests.
- [x] T030 Run `just unit`.
- [ ] T031 Regenerate any gist/output artifacts only from the executable,
  after the executable exists again.
