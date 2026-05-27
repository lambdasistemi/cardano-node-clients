# Tasks: lib-block-indexer multi-handler refactor

**Input**: [spec.md](./spec.md), [plan.md](./plan.md)  
**Source issue**: [lambdasistemi/cardano-node-clients#166](https://github.com/lambdasistemi/cardano-node-clients/issues/166)  
**PR**: [#167](https://github.com/lambdasistemi/cardano-node-clients/pull/167)  
**Execution model**: One slice = one visible driver+navigator pair = one
reviewed commit. The ticket owner writes slice briefs and verifies commits;
workers make all behavior-changing edits.

## Bootstrap

- [X] T000 Add PR-local `gate.sh`, run baseline `just ci`, `just e2e`, and
  `./gate.sh`, then open draft PR #167.

## Slice 1: `package-shell` - lib-block-indexer package shell

**Goal**: Establish the public sublibrary and module namespace without moving
behavior.

**Owned files**:
`cardano-node-clients.cabal`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Types.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Handler.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Engine.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Readiness.hs`.

- [X] T001 Create the `block-indexer` public sublibrary in
  `cardano-node-clients.cabal` with minimal existing dependencies only.
- [X] T002 Add Haddock-complete skeleton modules under `lib-block-indexer/`.
- [X] T003 Prove `nix develop --quiet -c cabal build all -O0` and `./gate.sh`
  pass with the shell in place.

**Commit**: `build(block-indexer): add package shell`  
**Trailer**: `Tasks: T001, T002, T003`

## Slice 2: `single-handler-engine` - move phase and transaction shell

**Goal**: Move generic phase dispatch and rollback transaction mechanics into
`lib-block-indexer` while still running one UTxO handler path.

**Owned files**:
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Types.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Handler.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Engine.hs`,
`lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Follower.hs`,
`cardano-node-clients.cabal`,
existing focused unit tests if imports need updates.

- [ ] T004 Move the `Runner.processBlock` phase wrapper and rollback-log
  transaction shell into `BlockIndexer.Engine`.
- [ ] T005 Keep `UTxOIndexer.Indexer` query/await/storage behavior compatible
  through a single UTxO handler path.
- [ ] T006 Preserve restoration sentinels, following rows, rollback pruning,
  EBB skipping, and replay-from-Origin behavior under existing tests.
- [ ] T007 Run focused unit tests for indexer/follower/persistence plus
  `./gate.sh`.

**Commit**: `refactor(block-indexer): move single-handler engine core`  
**Trailer**: `Tasks: T004, T005, T006, T007`

## Slice 3: `readiness-lag` - generic readiness and lag guard

**Goal**: Move reusable readiness state and lag guard helpers into
`lib-block-indexer` without changing daemon JSON or reconnect behavior.

**Owned files**:
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Readiness.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Follower.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Daemon.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Server.hs` only if import/type aliases
are required,
`test/Cardano/Node/Client/UTxOIndexer/FollowerSpec.hs`,
`test/Cardano/Node/Client/UTxOIndexer/DaemonSpec.hs`,
`cardano-node-clients.cabal`.

- [ ] T008 Move generic `Readiness` fields and upstream-status update helper
  into `BlockIndexer.Readiness`.
- [ ] T009 Add/keep a generic lag guard helper that derives ready/not-ready
  from processed slot, tip slot, upstream status, and threshold.
- [ ] T010 Keep `ReadyStatus` wire encoding and disconnect semantics
  byte-compatible for the bundled UTxO daemon.
- [ ] T011 Run readiness/reconnect focused tests plus `./gate.sh`.

**Commit**: `refactor(block-indexer): share readiness and lag guard`  
**Trailer**: `Tasks: T008, T009, T010, T011`

## Slice 4: `multi-handler-live-utxo` - handler composition

**Goal**: Introduce the multi-handler interface and port UTxO live indexing to
`liveUtxoHandler`.

**Owned files**:
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Types.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Handler.hs`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/Engine.hs`,
`lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Follower.hs`,
`test/Cardano/Node/Client/UTxOIndexer/FollowerSpec.hs`,
`test/Cardano/Node/Client/UTxOIndexer/IndexerSpec.hs`,
`cardano-node-clients.cabal`.

- [ ] T012 Define and expose `IndexerHandler cols inv` and the engine-level
  composite handler/inverse machinery.
- [ ] T013 Change block application so all registered handlers execute in one
  transaction per block and rollback fans out deterministically.
- [ ] T014 Expose and use
  `liveUtxoHandler :: InterestSet -> IndexerHandler Cols [UtxoOp]`.
- [ ] T015 Prove existing `InterestSet` semantics remain unchanged.
- [ ] T016 Run focused handler/indexer/follower tests plus `./gate.sh`.

**Commit**: `refactor(utxo-indexer): port live utxo to handler interface`  
**Trailer**: `Tasks: T012, T013, T014, T015, T016`

## Slice 5: `exports-haddock` - public exports and docs

**Goal**: Stabilize the public module surface and document how existing and new
consumers should depend on the split libraries.

**Owned files**:
`cardano-node-clients.cabal`,
`lib-block-indexer/Cardano/Node/Client/BlockIndexer/*.hs`,
`lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs`,
`lib/Cardano/Node/Client/UTxOIndexer/Follower.hs`,
`README.md` or `app/utxo-indexer/README.md` if public usage notes need a
small update.

- [ ] T017 Ensure exported modules and Haddock expose `block-indexer` concepts
  without leaking UTxO internals.
- [ ] T018 Keep existing UTxO public exports source-compatible or document the
  compatibility shim in Haddock.
- [ ] T019 Run `nix develop --quiet -c cabal build all -O0` and `./gate.sh`.

**Commit**: `docs(block-indexer): document handler split`  
**Trailer**: `Tasks: T017, T018, T019`

## Slice 6: `multi-handler-tests` - composition proof and full gate

**Goal**: Add a focused multi-handler regression test and re-run the full
behavior-equivalence proof.

**Owned files**:
`test/Cardano/Node/Client/UTxOIndexer/FollowerSpec.hs` or a new focused
`test/Cardano/Node/Client/BlockIndexer/*Spec.hs`,
`test/unit-main.hs`,
`cardano-node-clients.cabal` if a new test module is added.

- [ ] T020 Add a RED multi-handler test with a trivial second handler proving
  roll-forward composition.
- [ ] T021 Extend the test to prove rollback fanout through the composite
  inverse.
- [ ] T022 Run `./gate.sh` and record the passing evidence.

**Commit**: `test(block-indexer): prove multi-handler composition`  
**Trailer**: `Tasks: T020, T021, T022`

## Finalization

- [ ] T023 Run final `./gate.sh` at HEAD.
- [ ] T024 Run the finalization audit against this task file.
- [ ] T025 Update PR #167 body with delivered behavior and remaining
  downstream non-goals.
- [ ] T026 Drop `gate.sh` in `chore: drop gate.sh (ready for review)` and
  push the final draft PR branch.

**Commit**: `chore: drop gate.sh (ready for review)`

## Dependencies & Execution Order

```text
T000
  -> Slice 1 package-shell (T001-T003)
  -> Slice 2 single-handler-engine (T004-T007)
  -> Slice 3 readiness-lag (T008-T011)
  -> Slice 4 multi-handler-live-utxo (T012-T016)
  -> Slice 5 exports-haddock (T017-T019)
  -> Slice 6 multi-handler-tests (T020-T022)
  -> Finalization (T023-T026)
```

Slices are sequential because each one changes the API surface the next slice
uses. Within a slice, the driver may do local RED/GREEN iteration, but the
slice returns exactly one commit after navigator approval.

## Verification Gates

- Fresh-worktree baseline already passed before T000:
  `nix develop --quiet -c just ci`, `nix develop --quiet -c just e2e`.
- Every implementation slice must pass `./gate.sh` before the driver commits.
- The ticket owner re-runs or verifies `./gate.sh` before accepting and
  pushing each slice commit.
