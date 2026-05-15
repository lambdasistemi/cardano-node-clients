---
description: "Tasks for issue #153 — TxBuild self-validates against ledger Phase-1"
---

# Tasks: TxBuild self-validates against ledger Phase-1

**Input**: Design documents in `/specs/153-txbuild-integrity-hash/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/txbuild-self-validation.md](./contracts/txbuild-self-validation.md),
[quickstart.md](./quickstart.md)

**Tests**: TDD is in force per project constitution. Every
implementation task has a RED test that precedes it. See
[quickstart.md](./quickstart.md) §2-3 for canonical test
recipes.

**Organization**: tasks are grouped by user story (US1, US2)
from [spec.md](./spec.md). Each user story is independently
testable per the spec's "Independent Test" criteria.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: parallelizable (different files, no incomplete-task
  dependencies)
- **[Story]**: which user story this task belongs to (US1 / US2)
- Each task names exact file paths

---

## Phase 1: Setup — Resolve Phase-0 research

**Purpose**: close every OPEN entry in
[research.md](./research.md) so implementation has zero
"NEEDS CLARIFICATION" left. No code changes yet.

- [ ] T001 Resolve R-001 in [research.md](./research.md): pick the exact
  `cardano-ledger-api` / `cardano-ledger-conway` function for
  Phase-1 validation. Verify it (a) catches
  `script_integrity_hash` mismatches and (b) does not run
  Plutus scripts. Update R-001 to RESOLVED with the chosen
  function name and Haddock link.
- [ ] T002 [P] Resolve R-002 in [research.md](./research.md): run the
  current `Cardano.Node.Client.Scripts.computeScriptIntegrity`
  against captured swap-cancel inputs in a one-off `ghci`
  session, record whether it reproduces the *body* hash
  (`03e9d7ed…1941`) or the *ledger* hash
  (`41a7cd57…dcf9`). Pick the right Conway hash function
  accordingly. Update R-002 to RESOLVED.
- [ ] T003 [P] Resolve R-003 in [research.md](./research.md): confirm
  the body-derived `Set Language` strategy and the helper
  signature (see [data-model.md](./data-model.md) E-3). Update
  R-003 to RESOLVED.
- [ ] T004 Resolve R-004 in [research.md](./research.md): audit
  `PParams` flow in `lib-tx-build/Cardano/Node/Client/TxBuild.hs`
  (lines 1042, 1066, 1288, 1296, 1774, 1782) and
  `lib-tx-build/Cardano/Node/Client/Balance.hs` (lines 444,
  569). Decide whether `PParamsBound era` newtype is needed
  (see [data-model.md](./data-model.md) E-1). Update R-004 to
  RESOLVED.
- [ ] T005 Resolve R-005: ask user whether to reuse the staged
  `test/fixtures/pparams.json` from the main repo or capture
  a fresh one. Do **not** absorb the staged file silently
  (memory `feedback_semantic_changes`, `feedback_investigate_bugs`).
  Update R-005 to RESOLVED.
- [ ] T006 Resolve R-006 in [research.md](./research.md): confirm
  the `UTxO ConwayEra` source at TxBuild finalize time, and
  whether reference inputs need an explicit merge with the
  spending UTxO before `applyTx`. Update R-006 to RESOLVED.
- [ ] T007 Add the "Summary of decisions" closing section to
  [research.md](./research.md), naming the ledger function,
  hash function, language-derivation, and PParamsBound
  decision. Single signed commit:
  `docs(specs/153): close phase-0 research`.

**Checkpoint**: every research entry in
[research.md](./research.md) reads RESOLVED. No code in
`lib-tx-build` has been touched yet.

---

## Phase 2: Foundational — test fixture infrastructure

**Purpose**: shared scaffolding both user stories need.
Blocks Phase 3.

- [ ] T008 Capture the issue-#153 swap-cancel reproduction
  inputs to `test/fixtures/mainnet-txbuild/swap-cancel-issue-153/`:
  `utxo.json`, `plan.hs` (or `plan.json`), and
  `expected-body.cbor.hex` for mainnet tx
  `84b2bb78f7f5dd2beb2830e8e6e88fd853a8f70ea73b161f0a0327de8c70146f`.
  Source the data from `amaru-treasury-tx` reproduction
  artifacts; do not redraft.
- [ ] T009 Capture a mainnet `pparams.json` snapshot for the
  epoch active when tx `84b2bb…0146f` was rejected, and
  write it to `test/fixtures/pparams.json` of this worktree.
  Source: this project's LSQ client (`GetCurrentPParams`)
  against a mainnet node socket, or
  `cardano-cli query protocol-parameters --mainnet
  --socket-path …` (same Ouroboros query underneath).
  **Do not use Blockfrost or any other external service**
  per memory `feedback_fix_own_tools` and R-005.
- [ ] T010 [P] Add helpers `loadPParams`, `loadUtxo`,
  `loadPlan` to `test/Cardano/Node/Client/TxBuildSpec.hs`
  (or a new sibling test module) per
  [quickstart.md](./quickstart.md) §2. Keep them small;
  no logic beyond JSON decode + lookup.

**Checkpoint**: test scaffolding compiles, fixtures
present, no functional change to `lib-tx-build`.

---

## Phase 3: User Story 1 — TxBuild refuses Phase-1-invalid bodies (P1) 🎯 MVP

**Goal**: per [spec.md](./spec.md) US1 — the build call
self-validates and returns an error rather than an invalid
body.

**Independent Test**: per
[spec.md](./spec.md) US1 — fixture-driven; build the
swap-cancel plan, assert `Right body`,
`scriptIntegrityHashTxBodyL == SJust 41a7cd57…dcf9`,
`applyTx pp utxo slot body == Right _`.

### RED tests for US1 — write FIRST, watch fail

- [ ] T011 [US1] Add failing golden in
  `test/Cardano/Node/Client/TxBuildSpec.hs` per
  [quickstart.md](./quickstart.md) §2 part 1: build
  swap-cancel offline, assert
  `body ^. scriptIntegrityHashTxBodyL ==
  SJust 41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9`.
  Confirm RED before moving on.
- [ ] T012 [P] [US1] Add failing Phase-1 assertion in
  `test/Cardano/Node/Client/TxBuildSpec.hs` per
  [quickstart.md](./quickstart.md) §2 part 2: build
  swap-cancel offline, assert the build call self-validated
  (the result `isRight`). Will fail because no self-
  validation step exists yet; confirm RED.
- [ ] T013 [US1] Add failing negative-build test per
  [quickstart.md](./quickstart.md) §3 in
  `test/Cardano/Node/Client/TxBuildSpec.hs`: deliberately
  invalid plan → expect
  `Left (LedgerFail (Phase1Rejected _))`. Currently no
  `Phase1Rejected` constructor exists and no self-
  validation runs — confirm RED.

### Implementation for US1

- [ ] T014 [US1] Extend `LedgerCheck` per
  [data-model.md](./data-model.md) E-2 in
  `lib-tx-build/Cardano/Node/Client/TxBuild.hs`: add
  `Phase1Rejected (ApplyTxError era)`, parameterize types
  by `era` as needed. Existing constructors retained
  (memory `feedback_destructive_api_mutations`). Single
  commit, compiles, but tests still RED.
- [ ] T015 [US1] If T004 decided in favor of
  `PParamsBound`: add the newtype in
  `lib-tx-build/Cardano/Node/Client/TxBuild.hs`
  (or a small sibling module), threaded through `build`
  per [data-model.md](./data-model.md) E-1. Single
  commit, compiles, tests still RED. If T004 decided
  *against*, skip this task and leave
  [data-model.md](./data-model.md) E-1 noted as "decided
  against; see R-004 summary".
- [ ] T016 [US1] Fix `computeScriptIntegrity` in
  `lib-tx-build/Cardano/Node/Client/Scripts.hs` per
  [data-model.md](./data-model.md) E-4 and the R-002 / R-003
  outcomes: accept `Set Language` derived from body, accept
  witness-set datums, use the Conway-form hash function from
  T002. Add `languagesUsedInBody` helper per
  [data-model.md](./data-model.md) E-3. T011 turns GREEN.
- [ ] T017 [US1] Update the three call sites of
  `computeScriptIntegrity` in
  `lib-tx-build/Cardano/Node/Client/TxBuild.hs` (lines 1042,
  1288, 1774) to feed the body-derived language set and
  the witness-set datums map. Compiles; T011 stays GREEN.
- [ ] T018 [US1] Add self-validation in TxBuild's
  finalize path per [contracts/txbuild-self-validation.md](./contracts/txbuild-self-validation.md)
  C-1, C-4: at the point the body is about to be returned,
  call the Phase-1 function chosen in T001 with the same
  `PParams` / `UTxO` / slot already in scope. On `Left e`,
  return `Left (LedgerFail (Phase1Rejected e))`; otherwise
  return the body. T012 and T013 turn GREEN.
- [ ] T019 [US1] Verify integrity-hash and Phase-1
  invariants in a property test
  (`test/Cardano/Node/Client/TxBuildSpec.hs`): generate a
  range of Conway PlutusV3-only TxBuild plans (script
  spend with inline datum, no datum-witness, simple
  redeemer); assert all build calls succeed and the
  returned bodies pass `applyTx`. Edge cases per
  [spec.md](./spec.md) "Edge Cases" section.

**Checkpoint**: US1 fully delivered. Build calls return
ledger-valid bodies or `LedgerFail` errors; the
swap-cancel reproduction matches the ledger's
expected hash; `just ci` passes.

---

## Phase 4: User Story 2 — close downstream duplicate-gate ticket (P1)

**Goal**: per [spec.md](./spec.md) US2 / FR-008 — the
companion `amaru-treasury-tx` ticket is closed as
superseded; no consumer carries a duplicate Phase-1 gate.

**Independent Test**: per [spec.md](./spec.md) US2 — a
grep across consumers (starting with
`amaru-treasury-tx`) finds zero post-TxBuild Phase-1
gates; the companion ticket is closed with a backlink
to PR #154.

### Tasks for US2

- [ ] T020 [US2] Locate the companion ticket on
  `lambdasistemi/amaru-treasury-tx`. Update PR #154's
  description with the ticket URL.
- [ ] T021 [US2] Run the verification grep from
  [quickstart.md](./quickstart.md) §4 across
  `amaru-treasury-tx` and any other known TxBuild
  consumer. Record findings (a) in PR #154's description
  (consumer list confirmed clean), and (b) as a comment
  on the companion ticket.
- [ ] T022 [US2] Close the companion ticket as
  superseded with a reference to PR #154 — only after
  Phase 3 has merged and the consumer grep returned
  clean. If the ticket is still in open-PR form
  (consumer-side patch), coordinate with user before
  closing (memory `feedback_no_push_upstream`).

**Checkpoint**: US2 fully delivered. The class of bug
that motivated issue #153 cannot recur via a missing
consumer gate, because the consumer gate is gone.

---

## Phase 5: Polish

- [ ] T023 [P] Update Haddock on
  `Cardano.Node.Client.Scripts.computeScriptIntegrity`
  and `languagesUsedInBody` in
  `lib-tx-build/Cardano/Node/Client/Scripts.hs` to
  describe the body-derivation rule and the Conway hash
  function used.
- [ ] T024 [P] Update Haddock on `LedgerCheck` and the
  build entry point in
  `lib-tx-build/Cardano/Node/Client/TxBuild.hs` to
  describe the Phase-1 self-validation contract and
  `Phase1Rejected`.
- [ ] T025 Refresh PR #154 description: replace the
  "Status: Draft — only the spec is in" preamble with
  the implementation summary (modules touched, tests
  added, fixture path, link to companion-ticket
  closure). Memory `feedback_update_pr_description`.
- [ ] T026 Run `nix develop --quiet -c just ci` locally
  (memory `feedback_always_local_ci`) and confirm green.
  Push, mark PR #154 ready for review.
- [ ] T027 Add a `## Recent Changes` line to
  `CLAUDE.md` summarizing this feature
  (auto-generated by `update-agent-context.sh`; verify
  the entry is correct).

---

## Dependencies

```text
Phase 1 (T001-T007)  ──►  Phase 2 (T008-T010)  ──►  Phase 3 (T011-T019)
                                                          │
                                                          ▼
                                                Phase 4 (T020-T022)
                                                          │
                                                          ▼
                                                Phase 5 (T023-T027)
```

- Within Phase 1: T002, T003 are parallel after T001
  produces enough context.
- Within Phase 2: T008 and T009 are sequential (T009
  depends on T005's outcome captured in T009);
  T010 [P] can start as soon as T008 lands.
- Within Phase 3: T011, T012 are parallel writes
  (different test fixtures, same file → sequential
  in practice). T014/T015 are sequential (type
  parameterization order). T016 must precede T017
  (signature change before call-site update). T018 is
  the last RED→GREEN flip.
- Phase 4 starts only after Phase 3 has merged to main
  (consumer-grep makes no sense before the fix lands).
  Per memory `feedback_test_before_merge` we may also
  want to run the MPFS / amaru-treasury-tx E2E against
  the unmerged branch before declaring Phase 3 done.
- Phase 5 polishes can interleave; T025 / T026 are the
  release gate.

---

## Implementation strategy

- **MVP** = Phase 3 (US1) only. The build self-validates,
  the swap-cancel reproduction is GREEN, and the bug is
  closed at the TxBuild layer. Even without Phase 4 /
  Phase 5, the original issue #153 is resolved.
- **Incremental delivery**: Phase 3 ships as PR #154's
  first reviewable round; Phase 4 closes the loop on the
  downstream consumer; Phase 5 polishes the surface.
- **Vertical commits** (memory
  `feedback_vertical_commits`): one commit per
  meaningful unit (RED test bundle, type extension,
  hash fix, language-set helper, self-validation hook,
  property test). No fixup commits — use `stg goto` /
  `stg refresh` per memory `feedback_stgit_retroactive_fixes`
  if anything needs amending.
- **Bisect-safe** (memory `feedback_bisect_safe_commits`):
  every commit compiles. The order RED → type-extend →
  hash-fix → call-site → self-validate keeps every
  intermediate state green-on-build, RED-on-target-test
  until the matching GREEN step.
