# Tasks — #200

## S1 storage (lib-utxo-indexer)

- [x] T001 Asset identity/key types and codecs (DM1–DM3, F0a–F0d)
- [x] T002 Ledger-free output view decoder (DM4, DM5, F1), cross-checked against the ledger
- [x] T003 `AssetIndex` and `MetaCol` columns, RocksDB families, missing-family creation (DM7, DM8)
- [x] T004 Asset maintenance in the per-op apply step for create/spend/rollback (DM10, I1)
- [x] T005 Provenance-carrying spend inverse and rollback-log tag 2; `await` reports the true creation point after rollback restoration, old rows unchanged (DM6, DM9, I4, R8a)
- [x] T006 Completeness marker and explicit unavailability (I7)
- [x] T007 Typed asset read with indexed point in one transaction (F2–F4, I5)
- [x] T008 Specs: create/move/split/spend/burn, replay, divergent block, rollback provenance, in-memory vs RocksDB, concurrency, pre-change store (I1–I7)

## S2 wire, docs, E2E (lib)

- [ ] T009 `utxos_with_asset` request parsing and `invalid_asset_query` errors (I10)
- [ ] T010 Response encoding: point, matches, quantity, created, datum, unavailability (wire schema v1)
- [ ] T011 Wire/parser/golden specs incl. empty and non-text names, same name under two policies, existing endpoints byte-stable (I3, I8, I9)
- [ ] T012 E2E devnet spec: mint, move, split, spend, burn via the daemon socket (I1, I4, I7)
- [ ] T013 `docs/usage/utxo-indexer.md`: runnable example, every field, errors, datum availability, `await` correction (R10, R8a)
