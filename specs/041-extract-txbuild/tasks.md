# Tasks: Extract TxBuild

**Input**: Design documents from `/specs/041-extract-txbuild/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/public-surface.md

**Tests**: Tests are required because this is a library extraction with
compatibility and dependency-boundary risk.

**Organization**: Tasks are grouped by user story to enable independent
implementation and testing of each story.

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the new component and boundary tooling.

- [ ] T001 Add public `library tx-build` stanza to `cardano-node-clients.cabal`
- [ ] T002 Create `lib-tx-build/Cardano/Node/Client/` source directory
- [ ] T003 [P] Add `scripts/check-tx-build-boundary.sh` with forbidden dependency checks
- [ ] T004 [P] Add `tx-build-tests` test-suite scaffold to `cardano-node-clients.cabal`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Move shared implementation before story-specific validation.

- [ ] T005 Move `lib/Cardano/Node/Client/Ledger.hs` to `lib-tx-build/Cardano/Node/Client/Ledger.hs`
- [ ] T006 Move `lib/Cardano/Node/Client/Balance.hs` to `lib-tx-build/Cardano/Node/Client/Balance.hs`
- [ ] T007 Move `lib/Cardano/Node/Client/TxBuild.hs` to `lib-tx-build/Cardano/Node/Client/TxBuild.hs`
- [ ] T008 Update `tx-build` build-depends in `cardano-node-clients.cabal` to include only allowed transaction-building dependencies
- [ ] T009 Update main library build-depends in `cardano-node-clients.cabal` to depend on `cardano-node-clients:tx-build`

**Checkpoint**: The extracted component exists and owns the implementation.

---

## Phase 3: User Story 1 - Use TxBuild Without Node Clients (Priority: P1) MVP

**Goal**: Downstream users can consume TxBuild and Balance without node-client dependencies.

**Independent Test**: `cabal build lib:tx-build -O0` succeeds and `scripts/check-tx-build-boundary.sh` passes.

### Tests for User Story 1

- [ ] T010 [US1] Run `cabal build lib:tx-build -O0` and record any missing dependency corrections in `cardano-node-clients.cabal`
- [ ] T011 [US1] Run `scripts/check-tx-build-boundary.sh` and confirm forbidden dependencies are absent

### Implementation for User Story 1

- [ ] T012 [US1] Remove any forbidden dependencies from the `tx-build` stanza in `cardano-node-clients.cabal`
- [ ] T013 [US1] Fix imports in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` so the component depends only on extracted modules and allowed packages
- [ ] T014 [US1] Fix imports in `lib-tx-build/Cardano/Node/Client/Balance.hs` so the component depends only on extracted modules and allowed packages

**Checkpoint**: TxBuild and Balance build through the extracted component only.

---

## Phase 4: User Story 2 - Existing Users Keep Working (Priority: P2)

**Goal**: Existing main-library imports and internal consumers remain source-compatible.

**Independent Test**: `just unit` and `cabal build cardano-node-clients:cardano-tx-generator -O0` compile through the compatibility path.

### Tests for User Story 2

- [ ] T015 [US2] Run focused TxBuild unit tests with `cabal test cardano-node-clients:unit-tests -O0 --test-options='--match "/TxBuild/"'`
- [ ] T016 [US2] Run focused Balance unit tests with `cabal test cardano-node-clients:unit-tests -O0 --test-options='--match "/balanceTx/"'`
- [ ] T017 [US2] Run `cabal build cardano-node-clients:cardano-tx-generator -O0`

### Implementation for User Story 2

- [ ] T018 [US2] Replace `lib/Cardano/Node/Client/Ledger.hs` with a compatibility wrapper re-exporting the extracted module
- [ ] T019 [US2] Replace `lib/Cardano/Node/Client/Balance.hs` with a compatibility wrapper re-exporting the extracted module
- [ ] T020 [US2] Replace `lib/Cardano/Node/Client/TxBuild.hs` with a compatibility wrapper re-exporting the extracted module
- [ ] T021 [US2] Update in-repo imports only where required by Cabal component visibility

**Checkpoint**: Current cardano-node-clients users still compile through old module names.

---

## Phase 5: User Story 3 - Maintainers Can Enforce The Boundary (Priority: P3)

**Goal**: The component boundary is documented and mechanically protected.

**Independent Test**: Boundary check fails for a simulated forbidden dependency and passes after the simulation is removed.

### Tests for User Story 3

- [ ] T022 [US3] Run positive boundary check with `scripts/check-tx-build-boundary.sh`
- [ ] T023 [US3] Temporarily add a forbidden dependency to the `tx-build` stanza and confirm `scripts/check-tx-build-boundary.sh` fails, then remove it

### Implementation for User Story 3

- [ ] T024 [US3] Document extracted TxBuild dependency usage in `docs/modules/txbuild.md`
- [ ] T025 [US3] Update `docs/architecture.md` to show TxBuild as an extracted non-network component
- [ ] T026 [US3] Update `README.md` to mention the transaction-building component and compatibility path

**Checkpoint**: Maintainers and downstream users can see and verify the boundary.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and cleanup.

- [ ] T027 [P] Run `just format`
- [ ] T028 [P] Run `just hlint`
- [ ] T029 Run `just unit`
- [ ] T030 Run `just build`
- [ ] T031 Update `specs/041-extract-txbuild/plan.md` status with completed work and verification results

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup completion and blocks all user stories.
- **US1 (Phase 3)**: Depends on Foundational.
- **US2 (Phase 4)**: Depends on US1 because wrappers should target the proven extracted component.
- **US3 (Phase 5)**: Depends on US1 and can run partly in parallel with US2 after the boundary exists.
- **Polish (Phase 6)**: Depends on selected user stories being complete.

### Parallel Opportunities

- T003 and T004 can run in parallel.
- T024, T025, and T026 can run in parallel after the extracted component name and compatibility path are stable.
- T027 and T028 can run in parallel after implementation edits are complete.

## Implementation Strategy

### MVP First

1. Complete Phase 1 and Phase 2.
2. Complete US1 and verify `lib:tx-build` builds without forbidden dependencies.
3. Stop and validate the dependency boundary before adding wrappers.

### Incremental Delivery

1. US1 proves the extracted non-network component.
2. US2 restores source compatibility through wrapper modules.
3. US3 documents and enforces the boundary.
4. Polish runs the broader local verification.
