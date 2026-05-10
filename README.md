# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols (N2C + N2N).

**[Documentation](https://paolino.github.io/cardano-node-clients/)**

## Features

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **Balance** -- exact-fee transaction balancing plus fee-dependent output convergence
- **TxBuild** -- Conway-era transaction builder DSL with `Peek`, `Ctx`, and `Valid`
- **N2C** -- LocalStateQuery + LocalTxSubmission over Unix socket

`Balance`, `TxBuild`, and the shared Conway transaction alias are also
available from the public `cardano-node-clients:tx-build` sublibrary.
That component is intentionally free of N2C, chain-follower, indexer,
daemon, socket, and RocksDB dependencies. The main
`cardano-node-clients` library re-exports the same module names for
existing users.

## Executables

- [`utxo-indexer`](app/utxo-indexer/) -- address->UTxO indexer daemon
  (in-memory or RocksDB-backed) exposing NDJSON snapshot/await over a
  Unix socket. In-process auto-reconnect on upstream-relay disconnect
  with full-jitter exponential backoff via `Control.Retry`, gated by
  an LSQ tip probe (issue
  [#97](https://github.com/lambdasistemi/cardano-node-clients/issues/97)).
- [`cardano-tx-generator`](app/cardano-tx-generator/) -- Antithesis-driven
  fan-out daemon that creates monotonic UTxO and address pressure on a
  node by driving deterministic transactions through a growing
  population of derived addresses.

## Testing

- Unit tests cover `balanceTx`, `balanceFeeLoop`, and the `TxBuild`
  convergence logic, including eval retry, fee oscillation, and
  `bumpFee`.
- E2E tests run against a real devnet for provider, chainsync,
  chain-population, `balanceFeeLoop`, and a submitted `TxBuild`
  transaction using `spend`, `payTo`, `payTo'`, `ctx`, `peek`,
  `valid`, `requireSignature`, and `validFrom`/`validTo`.

## Build

```bash
nix develop -c just build
nix develop -c just ci       # format + lint + build
nix develop -c cabal build lib:tx-build -O0
```

## License

[Apache-2.0](LICENSE)
