# Tasks: Provider acquired query session

**Input**: Design documents in [`specs/041-provider-acquired-session/`](./).
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/provider-api.md](./contracts/provider-api.md), [quickstart.md](./quickstart.md).
**Tests**: TDD; failing E2E compile/test before implementation.
**Source issue**: [lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126).

## Phase 1: Setup

- [x] T001 Confirm `nix develop --quiet -c just ci` passes on the fresh issue worktree.

## Phase 2: Tests

- [x] T002 [US1] Add an E2E test in `test/Cardano/Node/Client/E2E/ProviderSpec.hs` that calls `withAcquired` and runs at least three handle queries in the same callback.
- [x] T003 [US2] Keep existing one-shot provider tests unchanged so they prove one-shot compatibility.

## Phase 3: Implementation

- [x] T004 Add `QueryHandle m`, handle selectors, and `withAcquired` to `lib/Cardano/Node/Client/Provider.hs`.
- [x] T005 Extend internal LSQ request types in `lib/Cardano/Node/Client/N2C/Types.hs`.
- [x] T006 Implement `withAcquiredLSQ` and `queryAcquiredLSQ` in `lib/Cardano/Node/Client/N2C/LocalStateQuery.hs`.
- [x] T007 Refactor `mkN2CProvider` in `lib/Cardano/Node/Client/N2C/Provider.hs` so one-shot methods delegate through the handle implementation.
- [x] T008 Update internal test stubs that construct `Provider` records.

## Phase 4: Docs and Verification

- [x] T009 Update `docs/modules/provider.md` with one-shot and acquired-session examples.
- [x] T010 Run `nix develop --quiet -c just ci`.
- [ ] T011 Push branch and open a PR closing issue #126.

## Dependency graph

```text
T001 -> T002 -> T004 -> T005 -> T006 -> T007 -> T008 -> T009 -> T010 -> T011
```
