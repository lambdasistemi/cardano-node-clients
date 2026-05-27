# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols (N2C + N2N).

**[Documentation](https://paolino.github.io/cardano-node-clients/)**

## Features

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **N2C** -- LocalStateQuery + LocalTxSubmission over Unix socket
- **block-indexer** -- generic chain-follower rollback/readiness
  helpers for building indexers without depending on UTxO internals
- **UTxOIndexer** -- address-keyed UTxO indexer fed by a chain-follower,
  exposing NDJSON snapshot/await over a Unix socket

Transaction building, balancing, blueprint-aware diffing, and the
`tx-diff` / `cardano-tx-generator` executables live in
[lambdasistemi/cardano-tx-tools](https://github.com/lambdasistemi/cardano-tx-tools).

## Executables

- [`utxo-indexer`](app/utxo-indexer/) -- address->UTxO indexer daemon
  (in-memory or RocksDB-backed) exposing NDJSON snapshot/await over a
  Unix socket. In-process auto-reconnect on upstream-relay disconnect
  with full-jitter exponential backoff via `Control.Retry`, gated by
  an LSQ tip probe (issue
  [#97](https://github.com/lambdasistemi/cardano-node-clients/issues/97)).

## Library Components

- `cardano-node-clients` contains the node-client APIs and bundled
  UTxO indexer follower/daemon surface.
- `cardano-node-clients:block-indexer` contains only generic
  rollback-log, handler-composition, and readiness helpers. It does
  not depend on UTxO columns, `InterestSet`, or `UtxoOp`.
- `cardano-node-clients:utxo-indexer-lib` contains the concrete UTxO
  storage columns, `liveUtxoHandler`, and the source-compatible
  `InterestSet` / `filterBlockOps` exports re-exported by the follower.

## Testing

- Unit tests cover the N2C probe and trace surface, the UTxO indexer
  (daemon, indexer, persistence, server, types), address parsing, and
  validity helpers.
- E2E tests run against a real devnet for provider, chainsync,
  chain-population, governance smoke, `balanceFeeLoop`, multi-asset
  change, a submitted `TxBuild` transaction, and the UTxO indexer
  (including a relay-restart reconnect scenario).

## Build

```bash
nix develop -c just build
nix develop -c just ci       # format + lint + build
```

## License

[Apache-2.0](LICENSE)
