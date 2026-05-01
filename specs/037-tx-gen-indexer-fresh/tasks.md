---

description: "Task list — gate tx-generator arms on indexer freshness after N2C reconnect (issue #109)"
---

# Tasks: Gate tx-generator arms on indexer freshness after N2C reconnect

**Input**: Design documents from `/specs/037-tx-gen-indexer-fresh/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, contracts/arm-gate.md, quickstart.md
**Issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/109
**Branch**: `037-tx-gen-indexer-fresh`

**Tests**: Required. Constitution principle II mandates real-devnet E2E for all node-communication features; principle IV mandates that test helpers are first-class library exports.

**Organization**: Tasks grouped by user story (US1, US2, US3) so each story can be implemented and demonstrated independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete work)
- **[Story]**: Maps to spec.md user stories
- Paths are absolute or relative to repo root

## Path Conventions

Single-project layout (per plan.md). Touched paths:

- `lib/Cardano/Node/Client/TxGenerator/Daemon.hs` — primary edit
- `test/Cardano/Node/Client/E2E/TxGeneratorIndexFreshSpec.hs` — new E2E spec
- (optional) `test/Cardano/Node/Client/TxGenerator/DaemonFreshGateSpec.hs` — pure unit test if a small helper is extracted

## Phase 1 — Setup

Trivial. No package boundary work, no new modules, no new dependencies.

- [X] T001 Verify worktree base is up-to-date with `origin/main` and that PR #105 (`feat(tx-generator): supervise N2C connection via N2C.Reconnect`) is the merge commit at `HEAD`. Run `git log --oneline -1` from `/code/cardano-node-clients-issue-109` and confirm the SHA matches `898a2c4`.

## Phase 2 — Foundational

Single foundational change, used by every user story below.

- [X] T002 Extend `data ReadyState` in `lib/Cardano/Node/Client/TxGenerator/Daemon.hs` (around line 217) with `rsIndexFresh :: !Bool`. Update `initialReady` (around line 225) to set `rsIndexFresh = False`. Run `nix develop -c cabal build all -O0` to confirm the change compiles in isolation (existing readers ignore the new field). Reference: data-model.md "Modified entity: `ReadyState`".

## Phase 3 — User Story 1: Refill arm gates on freshness (P1)

**Story goal**: post-reconnect refill arm short-circuits with `index-not-ready` until the indexer applies one new block.

**Independent test**: deterministic E2E — devnet relay → daemon → restart relay → assert refill returns `index-not-ready` during the freshness window → wait for one block → assert refill proceeds.

- [X] T003 [US1] In `lib/Cardano/Node/Client/TxGenerator/Daemon.hs`, in the `setUpstreamStatus` closure (around line 322), add `rsIndexFresh = False` to the `UpstreamConnected` branch's record update so the field is cleared on every reconnect (and on cold start). Reference: research.md Decision 2.
- [X] T004 [US1] In the same file, in `updateReady` (around line 1089), add `rsIndexFresh = True` to the `modifyTVar'` block so the freshness flag flips true after the first applied `RollForward`. Reference: research.md Decision 3, data-model.md "State transitions".
- [X] T005 [US1] In `runDaemonWithTracer` (around the `doRefill = ...` definition near line 399), wrap the existing body so the function first reads `rsIndexFresh` from `readyVar` via `readTVarIO` and, if `False`, returns `pure (RefillFail IndexNotReady)` *before* the existing `E.handle ConnectionLost` wrapper runs. Reference: research.md Decision 4, contracts/arm-gate.md "Refill arm contract".
- [X] T006 [P] [US1] Add E2E spec `test/Cardano/Node/Client/E2E/TxGeneratorIndexFreshSpec.hs`. Spec: spin up devnet, boot the daemon, wait for `ready=true`, stop the relay, restart the relay, immediately ping refill, assert `{"ok": false, "reason": "index-not-ready"}`, wait for one new block, ping refill again, assert it proceeds (or fails for an unrelated reason — the assertion is "no longer `index-not-ready`"). Pattern after `test/Cardano/Node/Client/E2E/TxGeneratorRestartSpec.hs`.
- [X] T007 [US1] Wire the new spec into `cardano-node-clients.cabal` under the existing `e2e-tests` test-suite `other-modules` section.

**Checkpoint**: After T007, `nix develop -c cabal test e2e-tests -O0 --test-show-details=direct --test-options='--match "TxGeneratorIndexFreshSpec"'` passes the refill assertions.

## Phase 4 — User Story 2: Transact arm gates on freshness (P1)

**Story goal**: post-reconnect transact arm short-circuits with `index-not-ready` until the indexer applies one new block.

**Independent test**: same E2E fixture as US1, exercising the transact arm.

- [X] T008 [US2] In `lib/Cardano/Node/Client/TxGenerator/Daemon.hs`, in the `doTransact = ...` definition (around line 419), apply the same wrapper as T005: read `rsIndexFresh`, return `pure (TransactFail IndexNotReady)` if `False`, otherwise fall through to the existing `E.handle ConnectionLost` + `runTransactArm` chain. Reference: contracts/arm-gate.md "Transact arm contract".
- [X] T009 [US2] In `test/Cardano/Node/Client/E2E/TxGeneratorIndexFreshSpec.hs`, add a sibling scenario asserting the transact arm short-circuits with `index-not-ready` during the same post-reconnect window and proceeds normally after one block.

**Checkpoint**: After T009, both refill and transact assertions in the new E2E spec pass.

## Phase 5 — User Story 3: Observability and threshold tuning (P2)

**Story goal**: short-circuited ticks are attributable to the freshness cause, and the antithesis run accommodates not-applicable streaks.

- [X] T010 [P] [US3] Confirm by reading `lib/Cardano/Node/Client/TxGenerator/Types.hs` (around line 145-146) that `IndexNotReady` already serialises as `"index-not-ready"` distinct from `NoPickableSource` (`"no-pickable-source"`). No code change. Document the conclusion in the PR body. Reference: contracts/arm-gate.md "NDJSON shape on the wire".
- [ ] T011 [US3] **Out-of-repo, tracked here for completeness**: open a companion issue or PR in `cardano-foundation/cardano-node-antithesis` titled `chore(composer): bump tx_generator_*_landed Sometimes-assertion thresholds for reconnect-storm tolerance`. Cross-link from issue #109. Do **not** edit anything in *this* repo for T011. Reference: research.md Decision 7, plan.md "out-of-scope contracts".

**Checkpoint**: After T010, the PR description for issue #109 explicitly states which `index-not-ready` cause is exercised by which path. After T011, the companion antithesis PR is filed and linked.

## Phase 6 — Polish & cross-cutting

- [ ] T012 Run the full local CI gate: `nix develop -c just ci`. This must build, run all E2E specs, fourmolu check, hlint, and cabal-fmt check. Fix anything that fails before pushing. Reference: workflow skill "Pre-Push CI Check".
- [ ] T013 Update the issue #109 description (and PR body once opened) with: link to spec 037, link to the companion antithesis PR from T011, summary of which acceptance criteria SC-001..SC-006 are verified by which test/process, and explicit note that SC-001..SC-004 require *both* this PR and the T011 companion to be merged before the 1h Antithesis run will go green.
- [ ] T014 Push the branch and open the GitHub PR (label: `fix`, assignee: `paolino`). Verify CI runs. Use merge-guard MCP to check before any merge. Do NOT auto-merge — wait for explicit user authorization.

## Dependencies

```
T001  ──►  T002  ──►  T003  ──►  T004  ──►  T005  ──►  T006  ──►  T007  ──►  T008  ──►  T009  ──►  T012  ──►  T013  ──►  T014
                                                          ▲                                ▲
                                                          └─ T006 may begin in parallel    └─ T009 depends on T006 (same file)
                                                             with T005 (different file)

T010  ──  independent  ──►  can begin any time after T002

T011  ──  out-of-repo, no dependency on this repo's tasks once research conclusions are documented
```

User-story independence: US1 (T003-T007) and US2 (T008-T009) share the freshness-flag plumbing (T003+T004), so US1 must be implemented first; US2 then becomes a one-line wrapper change plus a sibling test scenario. US3 is documentation-only inside this repo plus a cross-repo task.

## Parallel execution opportunities

- T006 (new E2E spec file) can be drafted in parallel with T005 (Daemon.hs wrapper) — different files.
- T010 (read Types.hs and confirm wire shape) is fully parallel: it touches no source.
- T011 lives in a different repository and has no dependency on the rest of this list once T010 has confirmed the wire vocabulary.

## Implementation strategy — MVP first

The MVP is **US1 alone** (T001-T007). Shipping US1 alone:

- Eliminates the `tx_generator_refill_submit_rejected` Always-assertion failure (the loudest of the two on the Antithesis run on `329a599`).
- Leaves `tx_generator_population_did_not_grow` failures still present until US2 lands, but does not regress anything.
- Is safe to merge incrementally if for any reason US2 (one-line transact wrapper + sibling test) needs to wait.

Practically, however, US2 is so cheap that this PR will ship US1+US2 together. US3 is documentation + cross-repo; it does not block this PR's merge.
