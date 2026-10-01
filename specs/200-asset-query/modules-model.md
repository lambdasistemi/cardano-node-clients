# Modules model — #200

Dependency direction is unchanged: `lib` → `utxo-indexer-lib` →
`block-indexer`. `utxo-indexer-lib` stays ledger-free; it may add a
dependency on `cborg` only.

| ID | Module | Change | Responsibility |
|---|---|---|---|
| M1 | `Cardano.Node.Client.UTxOIndexer.Types` | extend | asset identity and key types and their byte codecs (DM1–DM3) |
| M2 | `Cardano.Node.Client.UTxOIndexer.TxOutView` | new, `utxo-indexer-lib` | ledger-free decoding of a stored output into its asset quantities and datum view (DM4, DM5); the single source for both maintenance and the wire datum field |
| M3 | `Cardano.Node.Client.UTxOIndexer.IndexerOp` | extend | provenance-carrying restore op (DM6) |
| M4 | `Cardano.Node.Client.UTxOIndexer.Columns` | extend | `AssetIndex` and `MetaCol` columns, codecs, rollback-log tag 2 (DM7–DM9) |
| M5 | `Cardano.Node.Client.UTxOIndexer.Indexer` | extend | maintenance inside the per-op apply step, inverse with provenance, completeness marker at open, typed asset read on the handle (DM10, F1–F4) |
| M6 | `Cardano.Node.Client.UTxOIndexer.Server` | extend (S2) | `utxos_with_asset` request, response, error codes (wire schema in spec.md) |
| M7 | `docs/usage/utxo-indexer.md` | extend (S2) | operator/integrator documentation (R10) |

Test placement: unit specs under `test/Cardano/Node/Client/UTxOIndexer/`
(the ledger cross-check for M2 lives there, since the test suite has the
ledger), E2E under `test/Cardano/Node/Client/E2E/`. New spec modules are
registered in `cardano-node-clients.cabal`.

No new abstraction is promoted upstream: `block-indexer` and the
`csHandlers` seam (#195) are untouched (plan D1).
