# Modules model — #207

Dependency direction unchanged: `lib` → `utxo-indexer-lib` →
`block-indexer`. No new package dependency.

| ID | Module | Change | Responsibility |
|---|---|---|---|
| P1 | `Cardano.Node.Client.UTxOIndexer.Columns` | extend | DM12 record codec (pure encode/decode) |
| P2 | `Cardano.Node.Client.UTxOIndexer.Indexer` | extend | `BuildCoverage`, `StoreCoverage`, `BuildCoverageRefusal` types; the claim decision as an `IndexerHandle` operation in one transaction (H1–H2); degraded store → unrecorded |
| P3 | `Cardano.Node.Client.UTxOIndexer.Follower` | extend | claim once per bracket before chain-sync; raise the refusal; expose the outcome on `FollowerHandle` (H3–H4) |
| P4 | `Cardano.Node.Client.UTxOIndexer.Disclosure` | extend | `unknown` values, `coverage_unknown` limit, mapping from store outcome (H5–H6) |
| P5 | `Cardano.Node.Client.UTxOIndexer.Server` | extend | encode the added values; nothing else |
| P6 | `Cardano.Node.Client.UTxOIndexer.Daemon` | change | disclosure coverage from the follower handle's outcome; delete `followerCoverage` (D5) |
| P7 | `docs/usage/utxo-indexer.md` | change | Coverage section, limits table (R7) |

Tests under `test/Cardano/Node/Client/UTxOIndexer/`, registered in
`cardano-node-clients.cabal`. Frozen pre-change servers used by
byte-stability specs are not edited.
