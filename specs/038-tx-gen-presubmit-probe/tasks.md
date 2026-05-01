---
description: "Task list for spec 038 — pre-submit chain-tip UTxO probe"
---

# Tasks: Pre-submit chain-tip UTxO probe in tx-generator

**Input**: Design documents from `/specs/038-tx-gen-presubmit-probe/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/provider.md](./contracts/provider.md), [quickstart.md](./quickstart.md)

**Tests**: spec mandates a new E2E spec (SC-004) and acceptance criterion in
the issue body explicitly names a unit test. Both kinds are included.

**Organization**: tasks are grouped by user story so each story can be
implemented and demoed independently. The MVP is US1 alone (refill arm
probe) — US2 (transact arm probe) follows the same pattern.

**Workflow note**: per memory, each task should land as part of a
*vertical* stgit patch — one concern, end-to-end through types → callers
→ tests, bisect-safe. The task list below is more granular than the patch
list; group adjacent tasks into one patch when commit time comes.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on
  incomplete tasks)
- **[Story]**: which user story this task serves (US1, US2). Phase 1 / 2 /
  Polish tasks have no story label.

## Path conventions

Single-project layout per [plan.md §Source layout](./plan.md). All paths
are repo-relative.

---

## Phase 1: Setup

Worktree, branch, and spec artifacts already exist (commit d595bdb). No
project-init tasks remain.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: ship the Provider extension and the `verifyInputsUnspent`
helper that both user stories consume. Until this phase lands, neither
arm can wire the probe.

**⚠️ CRITICAL**: No US1 or US2 work begins until this phase is complete.

- [ ] T001 Add `queryUTxOByTxIn :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))` field to the `Provider` record in `lib/Cardano/Node/Client/Provider.hs` per the diff in [contracts/provider.md](./contracts/provider.md). Add the `Data.Set` and `Data.Map` imports as needed.
- [ ] T002 Implement `queryUTxOByTxIn` for the N2C provider in `lib/Cardano/Node/Client/N2C/Provider.hs`. Use the already-imported `pattern GetUTxOByTxIn` (currently at line 66) wrapped in `BlockQuery $ QueryIfCurrentConway`. On `QueryResultEraMismatch`, raise `ConnectionLost` to match the existing failure-mode contract. Depends on T001.
- [ ] T003 Update every in-tree stub of `Provider IO` to include the new `queryUTxOByTxIn` field so the build stays green. Search points: `test/`, `e2e-test/`, and any in-`lib` test helper. Stubs that don't exercise the probe may return `Map.empty` from the new field. Depends on T001.
- [ ] T004 Add `verifyInputsUnspent :: Provider IO -> Set TxIn -> IO Bool` to `lib/Cardano/Node/Client/TxGenerator/Selection.hs` (export it from the module). Implementation per [contracts/provider.md §Helper](./contracts/provider.md). Depends on T001.

**Checkpoint**: build green; both arms can now consume the probe in their respective phases.

---

## Phase 3: User Story 1 — Refill arm pre-submit probe (Priority: P1) 🎯 MVP

**Goal**: refill arm verifies its single faucet input against the relay's
current tip before invoking `submitTx`. On any input missing, short-circuit
with `RefillFail IndexNotReady` and skip submit.

**Independent Test**: per [spec.md US1 Independent Test](./spec.md). Drive
two refills across a `withRestartableCardanoNode` restart that lands Tx1
but raises `ConnectionLost` before MsgAcceptTx round-trips back; assert
the second refill returns `IndexNotReady`, no submit is attempted, and no
`"already been included"` rejection is observed.

### Tests for User Story 1

- [ ] T005 [P] [US1] Unit test for `verifyInputsUnspent` in `test/Cardano/Node/Client/TxGenerator/SelectionSpec.hs`. Two cases:
  - All requested inputs present in the stubbed `queryUTxOByTxIn` result → `True`.
  - One input missing → `False`.
  Use a `Provider` stub built with `Map.fromList`-backed `queryUTxOByTxIn`. Reference the test scaffolding pattern already in `SelectionSpec`.

### Implementation for User Story 1

- [ ] T006 [US1] Wire pre-submit probe in `buildSignSubmit` (refill arm) at `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:603–606`. Insert the call between `addKeyWitness faucetSKey tx` (line 604) and `submitTx submitter signed` (line 605):
  ```
  ok <- verifyInputsUnspent provider (Set.fromList (txInputs signed))
  if not ok then pure (RefillFail IndexNotReady) else <existing submit path>
  ```
  Verify the existing `E.handle ConnectionLost` wrapper at lines 438–444 still covers the new probe call (it does, because `queryUTxOByTxIn` raises `ConnectionLost` on LSQ unavailability — see [research.md D3](./research.md)).

- [ ] T007 [US1] Create new E2E spec `e2e-test/Cardano/Node/Client/E2E/TxGeneratorSubmitIdempotenceSpec.hs` covering the refill case. Model on `TxGeneratorRestartSpec.hs` (lines 1–80) using `Devnet.withRestartableCardanoNode`. Implement the shape from [quickstart.md §2](./quickstart.md): boot, drive refill 1 with forced ConnectionLost mid-write, wait for Tx1 to land, drive refill 2, assert `IndexNotReady` and no submit attempted. Pick the ConnectionLost-injection mechanism per [plan.md R2](./plan.md) — start with stop-restart, fall back to LTxS-channel wrapper if flaky.

- [ ] T008 [US1] Register the new test module in `cardano-node-clients.cabal` under the `e2e-tests` test suite (currently around line 295). Add `Cardano.Node.Client.E2E.TxGeneratorSubmitIdempotenceSpec` to `other-modules`.

**Checkpoint**: US1 fully functional. `cabal test e2e-tests --test-options='--match "tx-generator submit idempotence"'` passes (refill case).

---

## Phase 4: User Story 2 — Transact arm pre-submit probe (Priority: P1)

**Goal**: transact arm verifies all K source inputs against the relay's
current tip before invoking `submitTx`. Same probe helper, second wiring
site.

**Independent Test**: per [spec.md US2 Independent Test](./spec.md). Same
restart harness as US1, exercised against the transact arm.

### Implementation for User Story 2

- [ ] T009 [US2] Wire pre-submit probe in `transactWithSource` (transact arm) at `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:845–858`. Insert the same `verifyInputsUnspent` call between `addKeyWitness srcSKey tx` and `submitTx submitter signed`. On `False`, return `TransactFail IndexNotReady`. Verify the existing `E.handle ConnectionLost` wrapper at lines 465–471 covers the new probe.

- [ ] T010 [US2] Extend `TxGeneratorSubmitIdempotenceSpec.hs` with a second test case covering the transact arm, mirroring the US1 case but driving the transact tick. Reuse the same restart harness from T007.

**Checkpoint**: US2 fully functional. Both refill and transact paths
short-circuit on probe failure. Full suite:
`cabal test e2e-tests --test-options='--match "tx-generator submit idempotence"'`.

---

## Phase 5: Polish & Cross-Cutting

- [ ] T011 Run `nix develop --quiet -c just ci` locally; resolve any fourmolu / hlint / cabal-fmt / build / e2e findings. Re-run until green.
- [ ] T012 Walk through [quickstart.md](./quickstart.md) §1 (unit) and §2 (E2E) end-to-end on a clean checkout to confirm acceptance criterion SC-004.
- [ ] T013 Open the PR (draft mode is fine) so the reviewer has a window into the stack. Title: `fix(tx-generator): pre-submit chain-tip UTxO probe to prevent duplicate-submit-after-reconnect`. Body: link this spec dir, list the two user stories, mention prerequisites #105 + #110, name the in-flight tx-id-tracking follow-up explicitly as out of scope. Apply `fix` label, assign `paolino`, add to the planner.
- [ ] T014 After PR opens: trigger Antithesis 1h `cardano_node_tx_generator` run against the downstream pin in https://github.com/cardano-foundation/cardano-node-antithesis/pull/98 with this branch's SHA pinned. Verify SC-001..SC-003 from [spec.md](./spec.md) — 0 refill_submit_rejected, 0 transact_submit_rejected, ≥3000 reconnects.

**Checkpoint**: ready for review and merge per workflow skill (merge guard, explicit per-PR auth).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: complete (worktree + spec artifacts on remote).
- **Phase 2 (Foundational)**: T001 → T002, T003, T004 (all three depend on T001; T002/T003/T004 are independent of each other).
- **Phase 3 (US1)**: depends on Phase 2 completion. T005 [P] runs alongside T006. T007 depends on T006 (probe must exist before E2E exercises it). T008 depends on T007 (cabal registers the new module).
- **Phase 4 (US2)**: depends on Phase 2 completion (NOT on Phase 3 — US2 can be developed and tested independently of US1). T010 depends on T007 (extends the same E2E module).
- **Phase 5 (Polish)**: depends on Phases 3 and 4.

### Within each user story

- Unit test (US1's T005) can be written before or alongside the helper wiring — it tests `verifyInputsUnspent` in isolation, not the arm.
- Probe wiring before E2E spec (the spec exercises the wired path).
- E2E spec before cabal registration (cabal entry needs the module to exist).
- Probe wiring is one site per story; minimal intra-story dependency surface.

### Parallel opportunities

- T002 and T003 can run in parallel after T001 (different files: `N2C/Provider.hs` vs. test stubs).
- T004 can run in parallel with T002 / T003 (different file: `Selection.hs`).
- T005 [P] can run in parallel with T006 (different files: `SelectionSpec.hs` vs. `Daemon.hs`).
- US1 (Phase 3) and US2 (Phase 4) wiring tasks (T006, T009) are in the **same file** (`Daemon.hs`) — keep them sequential within stgit to avoid conflicts, but they could be split across PRs if needed.

---

## Implementation Strategy

### MVP (US1 only)

1. Phase 2 (T001..T004) — Provider extension + helper.
2. Phase 3 (T005..T008) — refill probe wiring, unit test, E2E spec.
3. Run `just ci`. Open draft PR. Demo: `cabal test e2e-tests --test-options='--match "tx-generator submit idempotence"'`.
4. **Stop and validate**: spec.md SC-004 passes locally on US1 alone. Already a shippable improvement — closes the refill-rejection class of failures.

### Incremental delivery

After MVP:
- Add Phase 4 (T009, T010) — transact probe wiring + E2E case.
- Run Phase 5 (T011..T014) — local CI, quickstart walkthrough, draft → ready PR, downstream Antithesis acceptance.

Each phase is a self-contained increment that compiles and passes its own
tests. Stack as separate stgit patches per [plan.md §Phase plan](./plan.md).

### Parallel-team strategy

Two-developer split possible after Phase 2:
- Developer A: Phase 3 (US1).
- Developer B: Phase 4 (US2) — but synchronize on `Daemon.hs` since both wire it.

In practice this is solo work; keep stgit patches strictly serialized.

---

## Notes

- [P] tasks = different files, no dependency on incomplete tasks.
- [Story] label maps task to spec.md user story.
- Verify build green after each task (bisect-safe).
- Commit after each logical group; do not batch unrelated tasks per memory.
- Tracks https://github.com/lambdasistemi/cardano-node-clients/issues/111.
