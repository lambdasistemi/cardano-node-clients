---

description: "Task list for 042-conway-stake-treasury — PR #132"
---

# Tasks: Conway stake certificates and treasury-withdrawal proposals

**Input**: Design documents in
`/specs/042-conway-stake-treasury/` —
`plan.md`, `spec.md`, `research.md`, `data-model.md`,
`contracts/txbuild-conway-api.md`, `quickstart.md`.

**Tests**: REQUIRED. Per the `pr` skill, every behaviour-changing slice
ships RED proof + GREEN implementation folded into one reviewed,
bisect-safe commit. Where RED and GREEN appear here as separate tasks
they collapse into a single git object at the end of the slice — the
"Fold into commit" note on each slice records exactly how.

**Organization**: Tasks are grouped by the six vertical slices from
`plan.md` (A–F). Each slice maps to a user-story phase below:

| Slice | Phase | Label | Acceptance criterion |
|-------|-------|-------|----------------------|
| A | Phase 3 | [USA] | 1, 2 |
| B | Phase 4 | [USB] | 3 |
| C | Phase 5 | [USC] | 4 |
| D | Phase 6 | [USD] | 5 |
| E | Phase 7 | [USE] | 7 |
| F | Phase 8 | [USF] | 6 |

Process acceptance (criterion 8) is enforced by the gate at every
slice and by the polish phase.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: independent of other tasks in the same slice; can run in parallel.
- **[USx]**: maps the task to a slice (USA–USF).
- File paths in every task are absolute-from-repo-root.

## Path Conventions

Repository root is `/code/cardano-node-clients-issue-130/`. All
production code under `lib-tx-build/`, all tests under `test/`, all
fixtures under `test/fixtures/mainnet-txbuild/`. Quality gate at
`llm/reviews/132/gate.sh`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Confirm the gate runs and the cabal stanzas exist before
slice work begins. No production code yet.

- [ ] T001 Run `llm/reviews/132/gate.sh` once on the current `HEAD` to baseline the inner loop green. This is the slice gate; the constitution-level `just ci` gate is run in Phase 9.
- [ ] T002 [P] Confirm `tx-build` library stanza in `cardano-node-clients.cabal` lists `cardano-ledger-conway` and `cardano-ledger-api` under `build-depends`.
- [ ] T003 [P] Confirm `tx-build-tests` and `e2e-tests` stanzas in `cardano-node-clients.cabal` have the same deps and an `other-modules` block we can extend.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: There is no shared prerequisite production code beyond
what slice A introduces; each slice is independent at the type level.
This phase is intentionally minimal — only the test scaffolding shared
across slices A–F.

**⚠️ CRITICAL**: Slices may not start until T004 is in place.

- [ ] T004 Add a shared Conway fixture helper module `test/Cardano/Node/Client/ConwayFixtures.hs` (deterministic `Credential 'Staking`, `RewardAccount`, `Anchor`, `ScriptHash`, `Coin` builders). Wired into `tx-build-tests` and `e2e-tests` `other-modules:` lists in `cardano-node-clients.cabal`. Used by slices A–F.

**Checkpoint**: Foundation ready — slice work can begin.

---

## Phase 3: Slice A — cert combinator + redeemer indexing (Priority: P1) 🎯 MVP

**Goal**: `certify :: ConwayTxCert ConwayEra -> CertWitness -> TxBuild q e Word32` is callable, emits the cert into `certsTxBodyL`, and produces a `ConwayCertifying (AsIx i)` redeemer for the `ScriptCert` branch at the final body-field index.

**Independent Test**: Property tests in `Cardano.Node.Client.TxBuildSpec` covering acceptance criteria 1 and 2 (script branch emits a redeemer at the right index; pub-key branch emits no redeemer). No interaction with golden vectors or devnet.

**Fold into commit**: T005 (RED test additions) + T006–T010 (GREEN implementation) ship as **one git commit**. Author writes the failing tests first locally, then implements, then squashes the working sequence with `git commit --amend` / `stg refresh` until the slice is one object whose pre-test state fails and post-implementation state passes.

### Tests for Slice A ⚠️ RED first

- [ ] T005 [USA] Add property tests to `test/Cardano/Node/Client/TxBuildSpec.hs`: (a) script-witnessed cert produces exactly one `ConwayCertifying (AsIx i)` redeemer at the index found by reading back the final `certsTxBodyL` `StrictSeq`, against a generated list of mixed pub-key / script certs; (b) pub-key-witnessed cert produces no redeemer. Use `mkHash28`, `mkRewardAccount`, and the new `ConwayFixtures` helpers.

### Implementation for Slice A

- [ ] T006 [USA] Add `CertWitness` ADT to `lib-tx-build/Cardano/Node/Client/TxBuild.hs` mirroring `SpendWitness` shape (existential `ToData r`). Place next to the other witness types around `TxBuild.hs:247`.
- [ ] T007 [USA] Extend `TxInstr q e` GADT in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` with the `Certify` constructor returning `Word32` (around `TxBuild.hs:280-331`).
- [ ] T008 [USA] Add `tsCerts :: [(ConwayTxCert ConwayEra, CertWitness)]` field to the internal `TxState` and thread accumulation through `interpretWith` in `lib-tx-build/Cardano/Node/Client/TxBuild.hs`.
- [ ] T009 [USA] Add `collectCertRedeemers` helper to `lib-tx-build/Cardano/Node/Client/TxBuild.hs` next to `collectSpendRedeemers` (around `TxBuild.hs:1630-1643`). Index is the position in the final `certsTxBodyL` `StrictSeq`.
- [ ] T010 [USA] Patch `assembleTx` in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` (around `TxBuild.hs:749-832`) to populate `certsTxBodyL` and fold the new redeemer list into the `Redeemers` map. Add `certify` smart constructor with the `Peek` fixpoint to return the final body-field `Word32`.

**Checkpoint**: Slice A commit is one object; gate (`./llm/reviews/132/gate.sh`) is green; the new property tests pass and the rest of `tx-build-tests` is unchanged. Acceptance criteria 1 and 2 satisfied.

---

## Phase 4: Slice B — `registerAndVoteAbstain` + cert golden (Priority: P2)

**Goal**: `registerAndVoteAbstain :: Credential 'Staking -> Coin -> CertWitness -> TxBuild q e Word32` emits exactly one combined Conway cert whose CBOR matches the `cardano-cli conway stake-address registration-and-vote-delegation-certificate --always-abstain` golden vector.

**Independent Test**: Golden test in `Cardano.Node.Client.TxBuildGoldenSpec` for acceptance criterion 3.

**Depends on**: Slice A (the underlying `certify` machinery).

**Fold into commit**: T011 (RED golden test + the fixture file) + T012 (GREEN smart constructor) ship as one git commit. The fixture file is committed in the same object so reviewing the slice tells the reader both what the CLI emits and what the DSL emits to match it.

### Tests for Slice B ⚠️ RED first

- [ ] T011 [USB] Generate the golden fixture pair using the `cardano-cli` invocation recorded in `quickstart.md`; commit it as `test/fixtures/mainnet-txbuild/conway-042/register-and-vote-abstain.cbor.hex` + `register-and-vote-abstain.inputs`. Add a golden case to `test/Cardano/Node/Client/TxBuildGoldenSpec.hs` that decodes the fixture as `ConwayTxCert ConwayEra`, builds the same cert via `registerAndVoteAbstain`, and compares the emitted `certsTxBodyL` entry with the decoded artifact.

### Implementation for Slice B

- [ ] T012 [USB] Add `registerAndVoteAbstain` smart constructor to `lib-tx-build/Cardano/Node/Client/TxBuild.hs` (delegates to `certify` with a hand-rolled `ConwayTxCert ConwayEra` value combining stake-credential registration and `DRepAlwaysAbstain` vote-delegation, with the deposit Coin from the caller).

**Checkpoint**: Slice B commit is one object; gate is green; new golden case passes. Acceptance criterion 3 satisfied.

---

## Phase 5: Slice C — proposal combinator + redeemer indexing (Priority: P3)

**Goal**: `propose :: ProposalProcedure ConwayEra -> ProposalWitness -> TxBuild q e Word32` is callable, emits the proposal into `proposalProceduresTxBodyL`, and produces a `ConwayProposing (AsIx i)` redeemer for the `GuardrailProposal` branch when the proposal procedure carries a guardrail script hash.

**Independent Test**: Property test in `Cardano.Node.Client.TxBuildSpec` for acceptance criterion 4: guardrail-script proposals emit the right redeemer, and proposals without guardrail scripts emit none.

**Depends on**: Phase 2 only (mirror of slice A; does not touch slice A code beyond `assembleTx` adjacency).

**Fold into commit**: T013 + T014–T018 ship as one git commit, same recipe as slice A.

### Tests for Slice C ⚠️ RED first

- [ ] T013 [USC] Add a property test to `test/Cardano/Node/Client/TxBuildSpec.hs`: `propose` with `GuardrailProposal r` and a proposal carrying `SJust guardrailScriptHash` produces a body entry plus a `ConwayProposing (AsIx i)` redeemer at the index found by reading back the final `proposalProceduresTxBodyL` `OSet`, for a generated list of proposals. `NoProposalScript` with `SNothing` guardrail produces no proposal redeemer.

### Implementation for Slice C

- [ ] T014 [USC] Add `ProposalWitness` ADT to `lib-tx-build/Cardano/Node/Client/TxBuild.hs` with `NoProposalScript` and existential `GuardrailProposal r`.
- [ ] T015 [USC] Extend `TxInstr q e` GADT in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` with the `Propose` constructor returning `Word32`.
- [ ] T016 [USC] Add `tsProposals :: [(ProposalProcedure ConwayEra, ProposalWitness)]` to `TxState` and thread accumulation through `interpretWith` in `lib-tx-build/Cardano/Node/Client/TxBuild.hs`.
- [ ] T017 [USC] Add `collectProposalRedeemers` helper to `lib-tx-build/Cardano/Node/Client/TxBuild.hs`. Index is the position in the final `proposalProceduresTxBodyL` `OSet`.
- [ ] T018 [USC] Extend `assembleTx` in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` to populate `proposalProceduresTxBodyL` and fold the new redeemer list into the `Redeemers` map. Add `propose` smart constructor with the `Peek` fixpoint.

**Checkpoint**: Slice C commit is one object; gate green; property test passes. Acceptance criterion 4 satisfied.

---

## Phase 6: Slice D — `proposeTreasuryWithdrawal` + proposal golden (Priority: P4)

**Goal**: `proposeTreasuryWithdrawal :: Coin -> RewardAccount -> Anchor -> Map RewardAccount Coin -> StrictMaybe ScriptHash -> ProposalWitness -> TxBuild q e Word32` emits one proposal procedure whose CBOR matches the `cardano-cli conway governance action create-treasury-withdrawal` golden vector.

**Independent Test**: Golden test in `Cardano.Node.Client.TxBuildGoldenSpec` for acceptance criterion 5.

**Depends on**: Slice C.

**Fold into commit**: T019 + T020 ship as one git commit, same recipe as slice B.

### Tests for Slice D ⚠️ RED first

- [ ] T019 [USD] Generate the golden fixture pair using the `cardano-cli` invocation recorded in `quickstart.md`; commit it as `test/fixtures/mainnet-txbuild/conway-042/treasury-withdrawal.cbor.hex` + `treasury-withdrawal.inputs`. Add a golden case to `test/Cardano/Node/Client/TxBuildGoldenSpec.hs` that decodes the fixture as `ProposalProcedure ConwayEra`, builds the same proposal procedure via `proposeTreasuryWithdrawal` with `SNothing` and `NoProposalScript`, and compares the emitted `proposalProceduresTxBodyL` entry with the decoded artifact.

### Implementation for Slice D

- [ ] T020 [USD] Add `proposeTreasuryWithdrawal` smart constructor to `lib-tx-build/Cardano/Node/Client/TxBuild.hs` (delegates to `propose` with a `TreasuryWithdrawals` `GovAction` carrying the supplied payee map and optional guardrail script hash; the consumer path passes `SNothing` with `NoProposalScript`).

**Checkpoint**: Slice D commit is one object; gate green; new golden case passes. Acceptance criterion 5 satisfied.

---

## Phase 7: Slice E — public exports + ledger re-exports + haddock (Priority: P5)

**Goal**: All new public symbols and required Conway ledger re-exports are listed in the explicit export list of `Cardano.Node.Client.TxBuild`, each carrying haddock per the `haskell` skill.

**Independent Test**: A small downstream importer compiles using only `Cardano.Node.Client.TxBuild` imports (no direct `cardano-ledger-*` imports needed for the consumer pattern in `quickstart.md`). Verified by adding a `tx-build-tests` compile-only fixture under `test/Cardano/Node/Client/TxBuildPublicApiSpec.hs` that imports the full surface from `Cardano.Node.Client.TxBuild` and references each new symbol once.

**Depends on**: Slices A–D.

**Fold into commit**: T021 (RED — the public-API import-surface test fails compilation when re-exports are missing) + T022 (GREEN — export-list edits) + T023 (haddock comments) ship as one git commit.

### Tests for Slice E ⚠️ RED first

- [ ] T021 [USE] Add `test/Cardano/Node/Client/TxBuildPublicApiSpec.hs`: a compile-only test module that imports `Cardano.Node.Client.TxBuild` and references every new public symbol and every new re-exported Conway ledger type from `contracts/txbuild-conway-api.md`. Wire it into the `tx-build-tests` `other-modules` block in `cardano-node-clients.cabal`.

### Implementation for Slice E

- [ ] T022 [USE] Extend the explicit export list at the top of `lib-tx-build/Cardano/Node/Client/TxBuild.hs` (`TxBuild.hs:21-90`) with `CertWitness (..)`, `ProposalWitness (..)`, including `NoProposalScript` and `GuardrailProposal`, `certify`, `registerAndVoteAbstain`, `propose`, `proposeTreasuryWithdrawal`, and the Conway ledger re-exports listed in `contracts/txbuild-conway-api.md`.
- [ ] T023 [USE] Add haddock to every new symbol in `lib-tx-build/Cardano/Node/Client/TxBuild.hs` per the `haskell` skill (one-line summary; explicit invariant for the returned `Word32` being the final body-field index for the four index-returning combinators).

**Checkpoint**: Slice E commit is one object; gate green; the public-API import-surface module compiles. Acceptance criterion 7 satisfied.

---

## Phase 8: Slice F — boundary smoke (`E2E.TxBuildConwaySpec`) (Priority: P6)

**Goal**: Live-devnet end-to-end smoke that submits the cert tx, asserts the script stake credential is registered with `DRepAlwaysAbstain` via LSQ, submits the proposal tx, and asserts the proposal procedure appears in the proposals snapshot.

**Independent Test**: `cabal test cardano-node-clients:e2e-tests -O0 --test-option=--match --test-option='/Cardano.Node.Client.E2E.TxBuildConwaySpec/'` (the exact invocation gated by `GATE_FULL=1` in `llm/reviews/132/gate.sh`).

**Depends on**: Slices A–E.

**Fold into commit**: T024 (the new spec module) + T025 (the cabal wiring) + T026 (the LSQ assertion helpers if not already present) ship as one git commit.

### Tests for Slice F (this slice's deliverable is itself the test) ⚠️

- [ ] T024 [USF] Add `test/Cardano/Node/Client/E2E/TxBuildConwaySpec.hs` modelled on the existing `E2E/TxBuildSpec.hs`: boots devnet via `withDevnet`, submits a tx using `registerAndVoteAbstain`, polls ledger state via LSQ, asserts the script stake credential is registered with `DRepAlwaysAbstain`; submits a second tx using `proposeTreasuryWithdrawal`, polls and asserts the proposal appears in the proposals snapshot with the exact deposit, return account, anchor, payee map, and `SNothing` guardrail.
- [ ] T025 [USF] Wire `Cardano.Node.Client.E2E.TxBuildConwaySpec` into the `e2e-tests` `other-modules` block in `cardano-node-clients.cabal`. Ensure the suite still builds without `GATE_FULL=1` (test module compiles always; only the runtime smoke is gated).
- [ ] T026 [USF] If LSQ queries for `DState` (cert delegation) and proposals snapshot do not yet exist in the test helpers, add minimal helpers under `test/Cardano/Node/Client/E2E/Queries.hs` (or extend an existing helper module) and wire them into `e2e-tests` `other-modules:`.

**Checkpoint**: Slice F commit is one object; `GATE_FULL=1 ./llm/reviews/132/gate.sh` is green. Acceptance criterion 6 satisfied.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Final reviewer audit before finalization.

- [ ] T027 Run `references/finalization.sh` from the `pr` skill against the branch; verify every non-review commit passes the commit-message gate, audit-trail commits are flat, and there is exactly one `_reviews` commit on top.
- [ ] T028 Run `llm/reviews/132/gate.sh` with `GATE_FULL=1` once end-to-end on the rebased branch, then run `nix develop --quiet -c just ci` for the constitution-level gate; record outputs under `llm/reviews/132/`.
- [ ] T029 [P] Re-read `quickstart.md` against the merged DSL surface and update if any symbol names drifted during slices A–E.
- [ ] T030 Update `llm/reviews/132/state.md` to `WaitingForFinalization`; solo-mode reviewer checklist (plan-review, tasks-review, per-slice code-review) recorded under `llm/reviews/132/`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies.
- **Phase 2 (Foundational)**: depends on Phase 1. Blocks slices A–F.
- **Phase 3 (Slice A)**: depends on Phase 2.
- **Phase 4 (Slice B)**: depends on Slice A.
- **Phase 5 (Slice C)**: depends on Phase 2. Independent of slices A and B.
- **Phase 6 (Slice D)**: depends on Slice C.
- **Phase 7 (Slice E)**: depends on Slices A, B, C, D.
- **Phase 8 (Slice F)**: depends on Slice E (uses the public symbols).
- **Phase 9 (Polish)**: depends on all of the above.

### Within Each Slice

- RED tests are committed in the same git object as the GREEN
  implementation; the slice's commit must fail to compile if the
  implementation is removed.
- All file edits inside a slice land in the same commit, even when
  spread across `lib-tx-build/`, `test/`, and the `.cabal` file.
- The author runs `./llm/reviews/132/gate.sh` before declaring the
  slice ready.

### Parallel Opportunities

- Slices A and C are independent and may be developed in parallel
  before being merged sequentially as separate commits.
- Within a slice, the RED test edits and the GREEN production edits
  touch different files (test vs library) and may be drafted in
  parallel before being squashed.

---

## Parallel Example: Slices A and C

```bash
# Draft slice A (cert path) and slice C (proposal path) in parallel:
Slice A: TxBuild.hs additions for Certify + collectCertRedeemers + assembleTx patch
Slice C: TxBuild.hs additions for Propose + collectProposalRedeemers + assembleTx patch
```

Once both compile in isolation, rebase so slice A lands first and
slice C lands on top with a clean diff that touches different ADT
constructors and different `TxState` fields.

---

## Implementation Strategy

### MVP First (Slice A only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational).
2. Complete Phase 3 (Slice A): `certify` + redeemer indexing alone is
   enough to exercise the new instruction family end-to-end at the
   property-test level (acceptance criteria 1, 2).
3. Stop. Run the gate. Validate that `tx-build-tests` is green and
   the rest of the suite is unaffected.

### Incremental Delivery

Each slice opens a reviewable, deployable, bisect-safe commit:

1. Setup + Foundational ready.
2. Slice A → property tests pass.
3. Slice B → golden cert vector matches CLI.
4. Slice C → proposal property tests pass.
5. Slice D → golden proposal vector matches CLI.
6. Slice E → public API surface fixed; downstream importer compiles.
7. Slice F → live-devnet smoke green under `GATE_FULL=1`.

### Solo Mode Notes

In solo mode (one actor, no GitHub state loop):

- The reviewer checklist (plan-review, tasks-review, per-slice code-review)
  is recorded as plain notes under `llm/reviews/132/` rather than
  enforced via GitHub-state transitions.
- `gh pr review --approve` is **not** run for own work; the slice
  finalization ends with `state: ReadyForExternalReview`.

---

## Notes

- `[P]` markers are intra-slice only; inter-slice parallelism is
  documented above.
- `[USx]` labels map every implementation task to a slice for
  traceability against `plan.md`.
- Per the `pr` skill: review fixes go back into the commit that
  introduced the issue (`git commit --amend` or `stg refresh`), never
  as fixup commits on top.
- Every code commit must pass the commit-message gate in
  `references/commit-gate.sh` from the `pr` skill — Slice E's `T022`
  in particular requires a precise subject because it lands the
  public surface.
