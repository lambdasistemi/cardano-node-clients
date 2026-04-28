# Tasks: cardano-tx-generator

**Input**: Design documents from `specs/034-cardano-tx-generator/`
**Prerequisites**: [plan.md](plan.md) (required), [spec.md](spec.md) (required), [research.md](research.md), [data-model.md](data-model.md), [contracts/control-wire.md](contracts/control-wire.md), [quickstart.md](quickstart.md)

**Per the `pr` skill, each task is one vertical commit**: types → callers → tests in one commit, bisect-safe (`just ci` green at every commit), no fixup commits — review feedback retroactively edits the originating commit via stgit.

**Per the "tasks reference contracts" feedback rule**, lists already specified in [data-model.md](data-model.md), [contracts/control-wire.md](contracts/control-wire.md), and [plan.md](plan.md) are referenced rather than re-listed inline.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Independent of any pending task — safe to take in parallel.
- **[Story]**: User story label (US1, US2, US3, US4) for story-phase tasks.
- File paths follow [plan.md](plan.md)'s structure decision.

## Path Conventions

Single Haskell project at the repo root. Library modules under `lib/Cardano/Node/Client/`; executable under `app/cardano-tx-generator/`; tests under `test/` (unit) and `e2e-test/` (integration with devnet).

---

## Phase 1: Setup (Shared Infrastructure)

**Status**: completed during specify + plan phases. No work to do here.

- [x] T001 — Branch `034-cardano-tx-generator` on origin; draft PR [#94](https://github.com/lambdasistemi/cardano-node-clients/pull/94); planner items [#84](https://github.com/lambdasistemi/cardano-node-clients/issues/84) + [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95) wired with blocked-by relationships.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: enable any user-story work. Must complete in order; each task is a vertical commit on this branch.

**⚠️ CRITICAL**: no User Story work begins until T007 is green.

- [ ] **T002** — Declare cabal targets: new library exposed-modules list (the `Cardano.Node.Client.TxGenerator.*` set named in [plan.md § Source code](plan.md#source-code-repository-root)) plus the new executable `cardano-tx-generator`. Each module is an empty stub `module X where` so the cabal builds. Also add `cabal-debug.project` extension if needed for local cross-repo overrides (per *Local dep override* feedback rule).
  Files: `cardano-node-clients.cabal`, plus stub `.hs` files at every module path in [plan.md § Source code](plan.md#source-code-repository-root).
  Satisfies: build hygiene only.
  Depends on: nothing.
  Bisect-safe gate: `just ci` build + cabal-check pass.

- [ ] **T003** [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95) — Add `runNodeClientFull` to `lib/Cardano/Node/Client/N2C/Connection.hs`. Extends `mkN2CApp`'s `[MiniProtocol]` list with a third entry for ChainSync (`MiniProtocolNum 5`) wired to the chain-sync client peer that `mkChainSyncN2C` already produces. Existing `runNodeClient` and `runChainSyncN2C` left untouched.
  Files: `lib/Cardano/Node/Client/N2C/Connection.hs`, plus signature export, plus an E2E smoke test `test/Cardano/Node/Client/E2E/N2CFullSpec.hs` that opens one connection and verifies all three protocols negotiate.
  Satisfies: FR-008.
  Depends on: T002.
  Bisect-safe gate: `just ci` + new E2E green.
  **Closes** [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95).

- [ ] **T004** — Implement `Cardano.Node.Client.TxGenerator.Persist` for the on-disk schema in [data-model.md § Persistent state](data-model.md#persistent-state-on-disk-under---state-dir). Atomic write semantics: tempfile + `fsync` + `rename` for `next-hd-index`; `master.seed` is read-only after creation.
  Files: `lib/Cardano/Node/Client/TxGenerator/Persist.hs`, `test/Cardano/Node/Client/TxGenerator/PersistSpec.hs` (covers concurrent reads against in-flight rewrite, crash-during-rename simulation).
  Satisfies: FR-003, FR-016.
  Depends on: T002.
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T005** [P] — Implement `Cardano.Node.Client.TxGenerator.Population` per [data-model.md § Population](data-model.md#population). Re-uses `mkSignKey`/`keyHashFromSignKey`/`enterpriseAddr` from `E2E.Setup`. Applies decision D3 from [research.md](research.md#d3--flat-deterministic-key-derivation-not-bip32).
  Files: `lib/Cardano/Node/Client/TxGenerator/Population.hs`, `test/Cardano/Node/Client/TxGenerator/PopulationSpec.hs` (determinism: same `(masterSeed, i)` → same key/address; distinct indices → distinct keys; reference vector of three derived addresses pinned in the test for replay-stability).
  Satisfies: FR-002 (partial — derivation is deterministic), FR-004.
  Depends on: T002. **Independent of T003 / T004 — can run in parallel.**
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T006** — Implement `Cardano.Node.Client.TxGenerator.Server` (NDJSON over Unix `SOCK_STREAM`) per [contracts/control-wire.md](contracts/control-wire.md). v1 handles `ready` and `snapshot` only — both initially against an empty/zero-population state. `transact` and `refill` return `{"ok":false,"reason":"index-not-ready"}` until later tasks wire them.
  Files: `lib/Cardano/Node/Client/TxGenerator/Server.hs`, `lib/Cardano/Node/Client/TxGenerator/Types.hs`, integration test `test/Cardano/Node/Client/TxGenerator/ServerSpec.hs` (round-trip JSON shapes; framing edge cases — partial line, oversized line, malformed JSON, unknown top-level key).
  Satisfies: FR-011, FR-012, FR-015 (failure-category vocabulary).
  Depends on: T002, T004, T005.
  Bisect-safe gate: `just ci` + integration green.

- [ ] **T007** — Wire `app/cardano-tx-generator/Main.hs`: parse CLI per [quickstart.md § CLI](quickstart.md#cli), open exactly one N2C connection via `runNodeClientFull` (T003), embed the indexer with `withInMemoryIndexer`, glue chain-sync to `applyAtSlot`/`rollbackTo` via the same `Intersector` pattern the merged indexer's `Daemon.hs` uses, query PParams once via LSQ at startup, mount T006's server on `--control-socket`, populate `daemonReadyVar` from the indexer's `ReadyStatus`. The `transact` and `refill` arms are still stubs returning `index-not-ready` if appropriate, but `ready` and `snapshot` are now meaningful.
  Files: `app/cardano-tx-generator/Main.hs`, E2E `e2e-test/Cardano/Node/Client/E2E/TxGeneratorReadySpec.hs` (boot daemon against `withDevnet`; observe `ready` transition from `false` to `true` within bounded time).
  Satisfies: FR-007, FR-008 (consumer side), partial of User Story 4.
  Depends on: T002, T003, T004, T005, T006.
  Bisect-safe gate: `just ci` + new E2E green.

**Checkpoint after T007**: foundation ready; user-story work can begin.

---

## Phase 3: User Story 2 — Refill from faucet (Priority: P2)

**Goal**: cold-start bootstrap and recurring refills work; the population grows by one fresh address per refill, the faucet's value drops accordingly.

**Independent Test**: send a single `{"refill": {"seed":1}}` against an empty population on a freshly-bootstrapped devnet; `populationSize` is 1, the new address holds non-zero ADA, the faucet's UTxO balance has dropped by exactly the paid amount + fee.

**Why Story 2 lands before Story 1**: transact requires value in the population. Refill is the simpler arm (one input → one output) and unblocks the rest.

- [ ] **T008** [US2] — Implement the refill arm end-to-end in one vertical commit. Adds:
  - `Cardano.Node.Client.TxGenerator.Build.refillTx` (TxBuild DSL composition for faucet → fresh address);
  - faucet-UTxO selection (highest-value UTxO at `--faucet-skey` derived address from the embedded index);
  - the `{"refill"...}` request handler in `Server.hs` per [contracts/control-wire.md § refill](contracts/control-wire.md#refill--pull-faucet--fresh-population-address);
  - the `RefillResult`-shaped response per [data-model.md § Refill request](data-model.md#refill-request);
  - bumping `nextHDIndex` via T004's atomic write before the response;
  - awaiting the new UTxO at the fresh address via the indexer's `awaitTxIn`.
  Files: `lib/Cardano/Node/Client/TxGenerator/Build.hs` (refill arm only), additions to `Server.hs`, additions to `Main.hs` to pass `--faucet-skey-file` through, E2E `e2e-test/Cardano/Node/Client/E2E/TxGeneratorRefillSpec.hs` covering Acceptance Scenarios 1 + 2 of [User Story 2](spec.md#user-story-2---refill-from-faucet-priority-p2).
  Satisfies: FR-013, partial of FR-014, FR-015 (`faucet-not-known`, `faucet-exhausted`).
  Depends on: T007.
  Bisect-safe gate: `just ci` + new E2E green; refill on a freshly-bootstrapped devnet is observable on chain.

---

## Phase 4: User Story 1 — Trigger one transaction (Priority: P1) 🎯 MVP

**Goal**: the core fan-out loop works end-to-end. After a refill, repeated `transact` requests grow the population and the UTxO set monotonically; replay against the same starting state and seed sequence produces byte-identical txIds.

**Independent Test**: with a refilled population, send 100 `{"transact":{"seed":N,"fanout":6,"prob_fresh":0.5}}` requests with distinct N. Per `populationSize` snapshot deltas, population grew by `≥ 100·6·0.5 − 5` ([SC-001](spec.md#measurable-outcomes)); replaying the same N sequence against the same starting state produces an identical txId sequence ([SC-002](spec.md#measurable-outcomes)).

**MVP increment**: combined with Phases 2 + 3 above, this delivers the Antithesis-driveable workload.

- [ ] **T009** [US1] [P] — Implement `Cardano.Node.Client.TxGenerator.Selection.pickSource` per [data-model.md § Source UTxO](data-model.md#source-utxo) and decision D10 from [research.md](research.md#d10--rng-mkstdgen-seed-per-request): uniform sample from `[0, nextHDIndex)`, indexer `snapshotAt`, viability check (`K · minUTxO + fee + minUTxO_for_change`), retry-with-rng-stream up to `--max-pick-retries` (default in [data-model.md](data-model.md)). Pure modulo the indexer query.
  Files: `lib/Cardano/Node/Client/TxGenerator/Selection.hs`, `test/Cardano/Node/Client/TxGenerator/SelectionSpec.hs` (StubIndexer that returns canned UTxO sets; assert deterministic source + retry behaviour for a fixed seed).
  Satisfies: FR-002, FR-006.
  Depends on: T005, T007.
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T010** [US1] [P] — Implement `Cardano.Node.Client.TxGenerator.Fanout.pickDestinations` per [data-model.md § Destinations](data-model.md#destinations) and decision D10: sequential per-output `prob_fresh` Bernoulli draw (fresh → mint a new index; else → uniform from existing population), per-output value drawn uniformly from `[minUTxO, available/K]` capped to keep the change above `minUTxO`. Returns the new `nextHDIndex`.
  Files: `lib/Cardano/Node/Client/TxGenerator/Fanout.hs`, `test/Cardano/Node/Client/TxGenerator/FanoutSpec.hs` (fixed-seed reference vectors for K=6 + prob_fresh=0.5; check sums; check value floor; check fresh-count distribution over many seeds).
  Satisfies: FR-002, partial of FR-005.
  Depends on: T005. **Independent of T009 — can run in parallel.**
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T011** [US1] — Wire the transact arm end-to-end: extend `Build.hs` with `transactTx` (1 input → K outputs + change), use `Balance.balanceTx` to compute fee + change, sign with `addKeyWitness`, submit via the LTxS channel, await `(txid, BalanceResult.changeIndex)` via the indexer with the `--await-timeout-seconds` bound. Wire the `{"transact"...}` handler per [contracts/control-wire.md § transact](contracts/control-wire.md#transact--submit-one-fan-out-transaction). Bump `nextHDIndex` atomically before responding (T004).
  Files: extensions to `lib/Cardano/Node/Client/TxGenerator/Build.hs`, additions to `Server.hs`, no schema additions to `Types.hs` beyond what T006 already declared.
  Satisfies: FR-001, FR-005, FR-009, FR-010, FR-014.
  Depends on: T008, T009, T010.
  Bisect-safe gate: `just ci` + e2e of T012 must drive this code green.

- [ ] **T012** [US1] — E2E for User Story 1: 100 sequential `transact` against a refilled population on devnet; assert all 100 land, `populationSize` grew within the SC-001 bound, replay determinism per SC-002 (same seed sequence + same starting state → identical txId list, byte-for-byte), not-applicable response under 1s for the dust-fragmented case (SC-004).
  Files: `e2e-test/Cardano/Node/Client/E2E/TxGeneratorTransactSpec.hs`.
  Satisfies: SC-001, SC-002, SC-004.
  Depends on: T011.
  Bisect-safe gate: full E2E green.

---

## Phase 5: User Story 3 — Snapshot for validators (Priority: P2)

**Goal**: the `snapshot` query returns useful aggregates so an Antithesis validator can assert monotonic growth and ongoing fragmentation.

**Independent Test**: take a snapshot, run N transacts, take another snapshot; the deltas in `populationSize` and percentiles match the predictions in [data-model.md § Snapshot](data-model.md#snapshot).

- [ ] **T013** [US3] — Implement `Cardano.Node.Client.TxGenerator.Snapshot.computeSnapshot` per [data-model.md § Snapshot](data-model.md#snapshot): walk `[0, nextHDIndex)`, call `snapshotAt addr_i` against the embedded indexer, flatten to `[Coin]`, sort, pick p10/p50/p90; tip from `daemonReadyVar`; last txid from `daemonLastTxIdVar`. Wire the `{"snapshot": null}` handler per [contracts/control-wire.md § snapshot](contracts/control-wire.md#snapshot--read-only-validator-query).
  Files: `lib/Cardano/Node/Client/TxGenerator/Snapshot.hs`, additions to `Server.hs`, unit tests with a `StubIndexer` covering empty population (percentiles `null`), single-address population, multi-address population.
  Satisfies: FR-011.
  Depends on: T007, T011.
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T014** [US3] — E2E for User Story 3 on devnet: refill, transact 50 times, snapshot; assert population size, p50 monotonically dropped from the post-refill snapshot, tip slot non-null. Coverage for [SC-005](spec.md#measurable-outcomes).
  Files: `e2e-test/Cardano/Node/Client/E2E/TxGeneratorSnapshotSpec.hs`.
  Satisfies: SC-005.
  Depends on: T013.
  Bisect-safe gate: full E2E green.

---

## Phase 6: User Story 4 — Readiness probe (Priority: P3)

**Goal**: `ready` reflects daemon liveness without false positives during cold start.

**Independent Test**: bring the daemon up while the relay is still bootstrapping; `ready` reports `false` with `indexReady=false`. After the relay catches up and a refill lands, `ready` reports `true` with all sub-flags `true`.

- [ ] **T015** [US4] — E2E for User Story 4: drive the cold-start sequence and assert the readiness state transitions described in [User Story 4 Acceptance Scenarios](spec.md#user-story-4---readiness-probe-priority-p3). Pure integration — no new module code, the logic was delivered by T007.
  Files: `e2e-test/Cardano/Node/Client/E2E/TxGeneratorReadyProbeSpec.hs`.
  Satisfies: User Story 4 acceptance scenarios.
  Depends on: T008 (refill is needed to flip `faucetUtxosKnown`).
  Bisect-safe gate: full E2E green.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] **T016** — Restart resilience E2E covering [SC-006](spec.md#measurable-outcomes): boot daemon, refill, run 50 transacts, `SIGTERM`, restart with same flags + same seed sequence resuming at index 51; assert byte-identical txIds for the post-restart segment.
  Files: `e2e-test/Cardano/Node/Client/E2E/TxGeneratorRestartSpec.hs`.
  Satisfies: SC-006.
  Depends on: T012.
  Bisect-safe gate: full E2E green.

- [ ] **T017** — Long-running scenario harness for [SC-007](spec.md#measurable-outcomes): a local equivalent of an Antithesis 3h composer-driven run — random `transact` / `refill` mix at variable cadence with random seeds — that asserts strictly-monotonic `populationSize` over the run modulo restarts/rollbacks. Not a unit test; runs under `--ci-extended` flag, skipped by default in `just ci`.
  Files: `e2e-test/Cardano/Node/Client/E2E/TxGeneratorEnduranceSpec.hs` (or analogous), invocation flag in the cabal test stanza.
  Satisfies: SC-007.
  Depends on: T015.
  Bisect-safe gate: scenario green when explicitly invoked.

- [ ] **T018** [P] — Documentation pass. Module haddocks on every public function in `Cardano.Node.Client.TxGenerator.*`; `app/cardano-tx-generator/README.md` mirroring [quickstart.md](quickstart.md) with absolute URLs; cross-link from the repo root README's component table.
  Files: `lib/Cardano/Node/Client/TxGenerator/*.hs` haddocks, `app/cardano-tx-generator/README.md`, `README.md`.
  Satisfies: project conventions.
  Depends on: T015.
  Bisect-safe gate: `just ci` (cabal-check enforces haddock presence on exports).

- [ ] **T019** — Final lint pass (full tree, not just touched files): `fourmolu`, `cabal-fmt`, `hlint`, `cabal check` per *Lint before push* feedback rule. Update PR description with the final state, request review, and unmark draft.
  Files: any whitespace/formatting nudges, PR body via `gh pr edit`.
  Satisfies: project conventions.
  Depends on: T018.
  Bisect-safe gate: `just ci` green over the full series (`stg goto` walk).

---

## Dependencies

```
T001  ── Setup (done)
   ↓
T002 ─┬→ T003 ───→ T007 ─┬→ T008 (US2) ─┬→ T011 (US1) ─→ T012 (US1) ─┬→ T016 (Polish)
      │  ↑              │              │                            │
      ├→ T004 ──────────┘              │                            ├→ T017 (Polish)
      │                                │                            │
      └→ T005 ─┬→ T006 ────────────────┘                            │
              │  ↑                                                  │
              └→ T009 (US1, [P]) ─┐                                 │
              └→ T010 (US1, [P]) ─┴→ T011 (above)                   │
                                  │                                 │
                                  ├→ T013 (US3) ─→ T014 (US3) ──────┤
                                  │                                 │
                                  └→ T015 (US4) ────────────────────┤
                                                                    │
                                                                    └→ T018 (Polish [P])
                                                                       └→ T019 (Polish)
```

## Parallel opportunities

- **T005** ‖ **T003** ‖ **T004** after T002 (three independent foundational pieces).
- **T009** ‖ **T010** after T005 + T007 (Selection vs Fanout share no files).
- **T018** is `[P]` against T016/T017 — docs don't depend on the polish E2Es.

## Implementation strategy

- **MVP** = Phases 1 + 2 + 3 + 4. After T012 the daemon delivers the core composer-driveable workload; Phases 5/6/7 are pressure-curve readability + production-readiness, not blockers for Antithesis adoption.
- **Vertical commits** per the `pr` skill — every task above is one commit, no horizontal "model commit + service commit + test commit" split. If a task touches more than ~300 LoC after rebasing review feedback, that's a smell — file a sub-issue and split.
- **stgit discipline** per *StGit discipline* feedback rule: every commit lands in stgit from the start, retroactive review fixes go via `stg goto <patch> + edit + refresh`, never via fixup commits on top.
- **Local CI before push** per *Always local CI* feedback rule: full `just ci` (build + unit + e2e) green before each `git push --force-with-lease`.

## Format validation

All task IDs are sequential (T001…T019). All Phase 3+ tasks carry a story label `[US1]` / `[US2]` / `[US3]` / `[US4]`. Setup, Foundational, and Polish tasks intentionally have no story label. Parallel candidates are tagged `[P]`. Every task names its owning files explicitly. Per the *Tasks reference contracts* feedback rule, no list already specified in [data-model.md](data-model.md), [contracts/control-wire.md](contracts/control-wire.md), or [plan.md](plan.md) is duplicated inline.
