# Modules model — #202

Dependency direction unchanged: `lib` → `utxo-indexer-lib` →
`block-indexer`. No new package dependency, no pin change.

| ID | Module | Change | Responsibility |
|---|---|---|---|
| M1 | `Cardano.Node.Client.UTxOIndexer.ColumnFamilies` | new, internal (`other-modules`) in `utxo-indexer-lib` | create named column families on an open RocksDB handle through the C API (D1); nothing else |
| M2 | `Cardano.Node.Client.UTxOIndexer.Indexer` | extend | open options, upgrade on request (DM11 states), backfill/resume task bound to the handle lifetime, `rebuilding` unavailability (F1–F4) |
| M3 | `Cardano.Node.Client.UTxOIndexer.Columns` | extend if needed | metadata key/value codecs for DM11 |
| M4 | `Cardano.Node.Client.UTxOIndexer.Server` | extend | map the new unavailability to reason `rebuilding`; nothing else (asset response fields belong to #201) |
| M5 | `Cardano.Node.Client.UTxOIndexer.Daemon` | extend (S2) | carry the request from `DaemonConfig` to the RocksDB constructor |
| M6 | `app/utxo-indexer/Main.hs` | extend (S2) | parse `--rebuild-asset-index` |
| M7 | `docs/usage/utxo-indexer.md` | extend (S2) | R10 |

Tests: unit specs under `test/Cardano/Node/Client/UTxOIndexer/`, E2E
under `test/Cardano/Node/Client/E2E/`, registered in
`cardano-node-clients.cabal`.
