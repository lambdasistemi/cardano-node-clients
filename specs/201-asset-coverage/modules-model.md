# Modules model — #201

Dependency direction unchanged: `lib` → `utxo-indexer-lib` →
`block-indexer`. No change to `utxo-indexer-lib` or `block-indexer`.

| ID | Module | Change | Responsibility |
|---|---|---|---|
| N1 | `Cardano.Node.Client.UTxOIndexer.Disclosure` | new, `lib` | coverage, freshness and limits types; the pure freshness/limits classifier (DD1–DD5, G1–G3); defines `ReadyStatus` with its last-progress field and its unchanged `ready` encoding |
| N2 | `Cardano.Node.Client.UTxOIndexer.Server` | extend | re-exports `ReadyStatus (..)`; disclosure argument; success-answer fields (spec wire additions). Imports N1, never the reverse |
| N3 | `Cardano.Node.Client.UTxOIndexer.Daemon` | extend | stale bound in `DaemonConfig`; coverage derived from the follower configuration; disclosure and last progress handed to the server (G4) |
| N4 | `app/utxo-indexer/Main.hs` | extend | `--stale-after-seconds` flag and usage line (J8) |
| N5 | `docs/usage/utxo-indexer.md` | extend | coverage, freshness and limits section (R8) |

Tests: unit and socket specs under `test/Cardano/Node/Client/UTxOIndexer/`,
E2E under `test/Cardano/Node/Client/E2E/`, registered in
`cardano-node-clients.cabal`. The frozen pre-change server used by the
byte-stability spec is not edited.
