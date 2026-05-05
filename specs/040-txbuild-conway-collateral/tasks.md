---

description: "Task list for 040-txbuild-conway-collateral"
---

# Tasks: TxBuild Conway collateral fields

**Input**: Design documents in [`specs/040-txbuild-conway-collateral/`](./).
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/txbuild-api.md](./contracts/txbuild-api.md), [quickstart.md](./quickstart.md).
**Tests**: TDD requested by user — failing tests precede implementation.
**Source issue**: [lambdasistemi/cardano-node-clients#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124).

## Format: `[ID] [P?] [Story] Description`

- **[P]** = parallel-safe (different file, no incomplete deps).
- **[Story]** = `[US1]`, `[US2]`, `[US3]` for user-story phases; omitted for shared phases.

## Path Conventions

Single-library Haskell layout:
- `lib/Cardano/Node/Client/{TxBuild,Balance}.hs` — feature implementation.
- `test/Cardano/Node/Client/{TxBuildSpec,TxBuildGoldenSpec}.hs` — unit tests.
- `test/Cardano/Node/Client/E2E/{TxBuildSpec,MultiAssetChangeSpec}.hs` — devnet E2E.

---

## Phase 1: Setup

**Purpose**: Branch + working tree are already in place. Confirm baseline.

- [ ] T001 Confirm `nix develop --quiet -c just ci` passes on the freshly-created `040-txbuild-conway-collateral` branch (baseline must be green so any later red is attributable to the feature work).

---

## Phase 2: Foundational

**Purpose**: Type-level scaffolding that every user story depends on. Per [data-model.md](./data-model.md).

**⚠️ CRITICAL**: No user-story work can compile until this phase lands.

- [ ] T002 Add new constructor `SetCollReturn :: Addr -> TxInstr q e ()` to `TxInstr` in `lib/Cardano/Node/Client/TxBuild.hs` (next to `SetValidFrom` / `SetValidTo` for visual symmetry).
- [ ] T003 Add field `tsCollReturnAddr :: StrictMaybe Addr` to `TxState` and initialise it to `SNothing` in `emptyState` in `lib/Cardano/Node/Client/TxBuild.hs`.
- [ ] T004 Handle the `SetCollReturn addr :>>= k` branch in `interpretWithM` in `lib/Cardano/Node/Client/TxBuild.hs` — last-write-wins (`tsCollReturnAddr = SJust addr`).
- [ ] T005 Add new constructor `CollateralShortfall !Coin !Coin` to `BalanceError` in `lib/Cardano/Node/Client/Balance.hs`. Update `Eq`/`Show` derivations as needed (they're auto-derived; verify no manual instance).
- [ ] T006 Confirm `nix develop --quiet -c cabal build all -O0` still compiles after T002–T005 (the new constructor adds a non-exhaustive-pattern warning; that's expected and resolved by the user-story tasks).

**Checkpoint**: Types are in place; the project still builds; no behavioural change yet.

---

## Phase 3: User Story 1 — Script-bearing tx is mempool-acceptable (Priority: P1) 🎯 MVP

**Goal**: A `TxBuild` program that spends a Plutus-locked UTxO and adds a collateral input now produces a body with `total_collateral` and `collateral_return` populated. Submission to a Conway node clears the collateral arithmetic predicate.

**Independent Test**: Build a minimal Plutus-spend-with-collateral tx via `build` and verify `total_collateral = ceil(fee × collateralPercent / 100)` and `sum(collateral_inputs.lovelace) = total_collateral + collateral_return.value.coin` exactly. Submit to devnet and confirm acceptance. (See [quickstart.md](./quickstart.md) for the canonical shape.)

### Tests for User Story 1 (FIRST — TDD)

- [ ] T007 [US1] Add a unit-test case to `test/Cardano/Node/Client/TxBuildSpec.hs` that runs `build` on a script-bearing program (one Plutus spend + one collateral input) against synthetic pparams and asserts: (a) `body ^. totalCollateralTxBodyL == SJust (ceil (fee × cp / 100))`, (b) the body's `collateral_return` exists and pays `collInLovelace − total_collateral` to the change address, (c) `length (toList (body ^. outputsTxBodyL)) == n + 1` (existing change behaviour preserved). The test must fail on `main`'s code path before T010–T013 land.
- [ ] T008 [US1] [P] Add an E2E test to `test/Cardano/Node/Client/E2E/TxBuildSpec.hs` (or extend `MultiAssetChangeSpec`) that submits a script-bearing tx via the local devnet and asserts the node accepts it (no `MissingCollateralInputs`/collateral-arithmetic error). The test must fail on `main`'s code path because the chain currently rejects the body.
- [ ] T009 [US1] Add an `Eq`/`Show` regression for `BalanceError` to `test/Cardano/Node/Client/E2E/BalanceSpec.hs` (or unit equivalent) covering the new `CollateralShortfall` constructor — to lock in FR-009 behaviour.

### Implementation for User Story 1

- [ ] T010 [US1] Implement private helper `lookupCollateralLovelace :: Set TxIn -> [(TxIn, TxOut ConwayEra)] -> Coin` in `lib/Cardano/Node/Client/Balance.hs` (folds `inputUtxos` filtered by the collateral input set, sums `coinTxOutL`).
- [ ] T011 [US1] Implement private helper `deriveCollateralFields :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> Addr -> Coin -> ConwayTx -> Either BalanceError (Maybe (Coin, TxOut ConwayEra))` in `lib/Cardano/Node/Client/Balance.hs` per the algorithm in [plan.md § Algorithm sketch](./plan.md). Returns `Right Nothing` when the body has no redeemers; `Left CollateralShortfall` when the collateral input sum is insufficient; `Right (Just (totalColl, returnOut))` otherwise.
- [ ] T012 [US1] Refactor `balanceTx` in `lib/Cardano/Node/Client/Balance.hs` to take an additional `Maybe Addr` parameter (collateral-return override) under a renamed primitive (e.g. `balanceTxWith`); keep the existing 5-arg `balanceTx` as a wrapper that passes `Nothing`. Inside the fee fixpoint's `buildTx fee` step, call `deriveCollateralFields`, wire `body & totalCollateralTxBodyL .~ ... & collateralReturnTxBodyL .~ ...` when the result is `Right (Just _)`. Surface `Left CollateralShortfall` as the loop's terminal `Left`.
- [ ] T013 [US1] Update `buildWith` in `lib/Cardano/Node/Client/TxBuild.hs` to compute the effective return address (`fromSMaybe changeAddr (tsCollReturnAddr st)`) and thread it through every `balanceTx`/`balanceTxWith` call site (4 sites: lines ~1011, ~1083, ~1336, ~1411 — confirm during implementation). The interpreted state's `tsCollReturnAddr` must reach the balancer; do not introduce a new top-level argument to `buildWith`.

### Verification for User Story 1

- [ ] T014 [US1] Run `nix develop --quiet -c just ci` and confirm: T007 passes, T008 passes (E2E green against devnet), T009 passes, no other `TxBuildSpec` golden vector regressed (SC-005). Commit.

**Checkpoint**: User Story 1 complete. Library produces submittable script-bearing Conway txs. MVP shippable from this commit.

---

## Phase 4: User Story 2 — Fee converges with collateral fields counted (Priority: P1)

**Goal**: The fee returned by `build` already accounts for the new fields' bytes — no `FeeTooSmallUTxO` rejection at submission, no shortfall vs. `cardano-cli`.

**Independent Test**: Build the swap-probe shape from [amaru-treasury-tx#18](https://github.com/lambdasistemi/amaru-treasury-tx/pull/18) and compare body byte length to `cardano-cli transaction build`'s output.

US2 implementation overlap with US1 is high (both are settled by extending the fee fixpoint). The remaining tasks are byte-level assertions and a guard against future regressions.

### Tests for User Story 2

- [ ] T015 [US2] Add a unit assertion to `test/Cardano/Node/Client/TxBuildSpec.hs`: for a script-bearing tx, the fee returned by `build` is at least `estimateMinFeeTx pp finalBody 1 0 refScriptBytes` (i.e. no shortfall). Use the same fixture as T007.
- [ ] T016 [US2] [P] Add a golden vector to `test/Cardano/Node/Client/TxBuildGoldenSpec.hs` for a deterministic script-bearing tx (fixed inputs, fixed pparams) so the body bytes are byte-locked across future changes.

### Implementation for User Story 2

No new code — US1's T010–T013 already place the fields inside the fee fixpoint. If T015 fails, treat as a US1 implementation bug and fix in `Balance.hs`.

### Verification for User Story 2

- [ ] T017 [US2] Run `nix develop --quiet -c just ci` and confirm both new assertions pass; commit if green.

**Checkpoint**: Fee accounting is complete. The library is production-ready for script-bearing Conway txs.

---

## Phase 5: User Story 3 — Caller redirects collateral return (Priority: P2)

**Goal**: A program calling `setCollateralReturn customAddr` sees the collateral leftover land at `customAddr`, not at the change address.

**Independent Test**: Build a script-bearing tx with `setCollateralReturn customAddr`; verify `body.collateral_return.address == customAddr` and the lovelace sum still balances.

### Tests for User Story 3

- [ ] T018 [US3] Add a unit test to `test/Cardano/Node/Client/TxBuildSpec.hs` that calls `setCollateralReturn customAddr` and asserts (a) the resulting body's `collateral_return` address matches `customAddr` (not `changeAddr`), (b) the lovelace value is unchanged from the default-address case (sum invariant still holds), (c) calling `setCollateralReturn` twice yields the second address (FR-010 last-write-wins).
- [ ] T019 [US3] [P] Extend the E2E `MultiAssetChangeSpec` (or `E2E/TxBuildSpec`) to exercise `setCollateralReturn` against a devnet node and assert the on-chain output address matches.

### Implementation for User Story 3

- [ ] T020 [US3] Add the smart constructor `setCollateralReturn :: Addr -> TxBuild q e ()` to `lib/Cardano/Node/Client/TxBuild.hs` (next to `setValidFrom`/`setValidTo`, with Haddock per the contract in [contracts/txbuild-api.md](./contracts/txbuild-api.md)). Export it from the module's export list.
- [ ] T021 [US3] Verify the new symbol is included in any haddock/quickstart doc snippets and resolves at the public-API surface.

### Verification for User Story 3

- [ ] T022 [US3] Run `nix develop --quiet -c just ci`; confirm T018 + T019 pass; commit.

**Checkpoint**: Override path complete. All three user stories shipped.

---

## Phase 6: Polish & cross-cutting

- [ ] T023 [P] Update CHANGELOG.md with a one-liner under "Unreleased" (e.g. `feat(tx-build): emit Conway total_collateral / collateral_return for script-bearing txs (#124)`).
- [ ] T024 [P] Sweep Haddock: ensure `setCollateralReturn`, `CollateralShortfall`, and the new field on `TxState` carry exported docstrings consistent with the rest of the module.
- [ ] T025 Run `nix develop --quiet -c just ci` one final time on the rebased branch; push the branch; open a PR linked to [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124) with a description that walks the reviewer through `Balance.hs`, the new `TxInstr` constructor, and the test additions.

---

## Dependency graph

```text
T001 (baseline)
  └── T002 ── T003 ── T004 ── T005 ── T006 (foundational types)
                                       ├── US1: T007, T008, T009 (failing tests)
                                       │     └── T010 ── T011 ── T012 ── T013 ── T014 (impl + verify)
                                       ├── US2: T015, T016 (assertions)
                                       │     └── T017 (verify; relies on US1 impl)
                                       └── US3: T018, T019 (failing tests)
                                             └── T020 ── T021 ── T022 (impl + verify)
                                                                   └── T023, T024, T025 (polish)
```

Edges to remember:
- T012 must happen before T013 (the `Maybe Addr` parameter must exist before `buildWith` threads it).
- T015's assertion can only pass after T012/T013 land — order it inside US1's verification window or run it post-T014.
- T020 (`setCollateralReturn`) is required for US3 tests to even compile; do NOT mark T018 as failing-on-`main`-without-T020 — the failure mode is a compile error, not a wrong body. Pair them in the same commit if working sequentially.

## Parallel opportunities

Limited — single library, two source files, two test files. The genuinely parallel pairs are:

- **T007 & T008**: unit and E2E tests for US1 touch different files and can be drafted concurrently before any impl work.
- **T015 & T016**: byte-assertion and golden vector for US2 — different files.
- **T018 & T019**: unit + E2E for US3 — different files.
- **T023 & T024**: CHANGELOG and Haddock sweep — different files.

Everything else is strictly sequential by file.

## Implementation strategy

- **MVP target**: complete through T014 (US1). At that point the library produces submittable script-bearing Conway txs and the chain accepts them — the headline outcome of the issue.
- **Incremental commits**: one commit per task ID for T002–T013 (vertical commits, bisect-safe per repo convention). T014, T017, T022 are verification-only — squash into the preceding impl commit if it stays green from the start.
- **Don't pre-merge**: per the user's "surge before merge" preference, push the branch, request review, only merge once the reviewer has had eyes on it.
