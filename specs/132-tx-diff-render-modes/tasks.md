# Tasks: tx-diff Render Modes

**Input**: [spec.md](./spec.md), [plan.md](./plan.md),
[research.md](./research.md), [contracts/cli.md](./contracts/cli.md)  
**Issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/139

## Phase 1: Setup

- [X] T001 Confirm implementation matches the final CLI contract: default `--render tree`, default `--tree-art ascii`, explicit `--render paths`, and explicit `--tree-art unicode`.
- [X] T002 Verify whether `tree-render-text` is available in the pinned Nix/Haskell package set and record the result in `specs/132-tx-diff-render-modes/research.md`.
- [X] T003 Decide whether implementation uses existing `containers` only or adds a renderer dependency; update `specs/132-tx-diff-render-modes/plan.md`.

## Phase 2: Foundational Tests

- [X] T004 [P] Add RED unit tests for tree grouping of sibling object changes in `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [X] T005 [P] Add RED unit tests for path-line compatibility in `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [X] T006 [P] Add RED unit tests for ASCII and Unicode tree art selection in `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [X] T007 Add RED CLI parsing/usage tests for invalid render values in the appropriate unit test module.

## Phase 3: User Story 1 - Tree Hierarchy

- [X] T008 [US1] Add renderer option types and tree renderer entry points in `lib/Cardano/Node/Client/TxDiff.hs`.
- [X] T009 [US1] Build a render tree from `DiffNode` without recomputing comparison in `lib/Cardano/Node/Client/TxDiff.hs`.
- [X] T010 [US1] Render object and array changed children under shared parent paths in `lib/Cardano/Node/Client/TxDiff.hs`.
- [X] T011 [US1] Update Conway renderer expectations for nested fee/output/datum paths in `test/Cardano/Node/Client/TxDiff/ConwaySpec.hs`.

## Phase 4: User Story 2 - Path Compatibility

- [X] T012 [US2] Preserve the existing path-line renderer behind an explicit render shape in `lib/Cardano/Node/Client/TxDiff.hs`.
- [X] T013 [US2] Ensure only-side object and array entries render correctly in path mode in `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.

## Phase 5: User Story 3 - Tree Art Selection

- [X] T014 [US3] Implement ASCII tree art rendering in `lib/Cardano/Node/Client/TxDiff.hs`.
- [X] T015 [US3] Implement Unicode tree art rendering or document why ASCII/plain is the accepted first release style.
- [X] T016 [US3] Add CLI flags for render shape and tree art in `app/tx-diff/Main.hs`.
- [X] T017 [US3] Update usage text and invalid-argument handling in `app/tx-diff/Main.hs`.

## Phase 6: Verification

- [X] T018 Run `nix develop --quiet -c just unit`.
- [X] T019 Run `nix develop --quiet -c just ci`.
- [X] T020 Update issue #139 with the chosen renderer dependency/art decision and verification evidence.

## Dependencies

- T001-T003 block implementation.
- T004-T007 must fail before T008-T017 begin.
- US1 is the MVP and can ship before US2/US3 only if the CLI contract is
  deliberately narrowed before implementation.
- US2 must complete before changing default behavior.
- US3 completes the user's render-art requirement.

## Parallel Opportunities

- T004, T005, and T006 can be drafted independently.
- T008-T010 should stay serial because they shape the renderer API.
- T014 and T016 can proceed in parallel after render option types exist.

## Implementation Strategy

Implement vertically by user story with TDD:

1. Establish the final CLI/render contract.
2. Write RED tests for tree hierarchy and compatibility.
3. Implement tree rendering without touching comparison logic.
4. Restore path compatibility.
5. Add art selection and CLI usage.
6. Run the full gate before PR.
