# Tasks: Balance-Aware ExUnits

**Input**: Design documents from `/specs/039-exunits-after-balance/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`

## Phase 1: Regression Coverage

- [ ] T001 [US1] Add a `build` unit regression in `test/Cardano/Node/Client/TxBuildSpec.hs` where evaluator CPU depends on final output count.
- [ ] T002 [US2] Add an `evaluateAndBalance` unit regression in `test/Cardano/Node/Client/TxBuildSpec.hs` with the same output-count evaluator.
- [ ] T003 Run the focused unit tests and confirm the new regressions fail before implementation.

## Phase 2: Implementation

- [ ] T004 [US1] Update `lib/Cardano/Node/Client/TxBuild.hs` so `buildWith` only converges when final balanced redeemer ExUnits are stable.
- [ ] T005 [US2] Update `lib/Cardano/Node/Client/Evaluate.hs` so `evaluateAndBalance` evaluates the balanced transaction, repatches redeemers, and rebalances until fee and ExUnits stabilize.
- [ ] T006 Preserve `boExUnitsMargin` semantics and script integrity recomputation for all patched redeemers.

## Phase 3: Verification

- [ ] T007 Run focused unit tests for TxBuild.
- [ ] T008 Run `just ci`.
- [ ] T009 Run the CI-parity Nix gate.
- [ ] T010 Update this task list and plan status with verification results.
