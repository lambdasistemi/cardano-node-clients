# Tasks — #202

## S1 library (lib-utxo-indexer, Server reason)

- [x] T001 Column-family creation on an open pre-change store (M1, F5, D1)
- [x] T002 Open options and upgrade on request; DM11 states; no-op on complete/empty stores (F1–F3, U4, U9)
- [x] T003 Online backfill and sweep bound to the handle, chunked, resumable; marker only on completion; extraction failure leaves `absent` (U2, U5, U10)
- [x] T004 `AssetIndexRebuilding` and wire reason `rebuilding` (F4, U3)
- [x] T005 Specs: close/reopen/resume equals never-closed store; upgrade of a seeded pre-change store; follower interleaving; interruption and resume; pre-change rows unchanged; `utxos_at`/`await`/`ready` stable (U1–U7, U9, U10)

## S2 daemon, E2E, docs

- [x] T006 `--rebuild-asset-index` through `DaemonConfig` (F6)
- [x] T007 E2E: daemon restart on the same `--db-path` against a devnet, asset answer before and after (U8)
- [x] T008 `docs/usage/utxo-indexer.md`: restart, upgrade procedure, answers during it, `rebuilding`, one-way upgrade (R10)
