# Tasks: ChainSyncConfig Handler-List Seam

## Slice 1 - Add `csHandlers` Field

- [ ] T001 Add `csHandlers :: NonEmpty (IndexerHandler Cols [UtxoOp])` to `ChainSyncConfig`.
- [ ] T002 Update required imports and `Show ChainSyncConfig`.
- [ ] T003 Update direct `ChainSyncConfig` construction sites to compile with the singleton UTxO handler default.
- [ ] T004 Run a focused build or unit command and commit as `feat(utxo-indexer): add ChainSyncConfig handler list`.

## Slice 2 - Wire Follower State

- [ ] T005 Route follower state creation/remapping through `csHandlers` instead of hardcoded `liveUtxoHandler`.
- [ ] T006 Preserve `csInterestSet` behavior for filtering and waiter bookkeeping.
- [ ] T007 Run focused follower/indexer tests plus `./gate.sh`.
- [ ] T008 Commit as `feat(utxo-indexer): use ChainSyncConfig handlers`.

## Slice 3 - Multi-Handler Regression

- [ ] T009 Add a unit test with `liveUtxoHandler IndexAll :| [trivialSecondHandler]`.
- [ ] T010 Assert roll-forward writes both the normal UTxO columns and the second handler's observable state.
- [ ] T011 Assert rollback restores both handlers symmetrically.
- [ ] T012 Run the focused unit test plus `./gate.sh`.
- [ ] T013 Commit as `test(utxo-indexer): cover ChainSyncConfig handler fanout`.

## Slice 4 - Haddock and Public Guidance

- [ ] T014 Document `csHandlers` and the recommended handler-extension pattern.
- [ ] T015 Verify module exports/imports are sufficient for downstream handler-list construction.
- [ ] T016 Run `./gate.sh`.
- [ ] T017 Commit as `docs(utxo-indexer): document follower handler seam`.

## Finalization

- [ ] T018 Update PR body with delivered behavior and testing evidence.
- [ ] T019 Run finalization audit for PR #169 and this task file.
- [ ] T020 Drop `gate.sh` in `chore: drop gate.sh (ready for review)`.
