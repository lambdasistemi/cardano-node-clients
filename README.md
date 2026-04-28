# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols (N2C + N2N).

**[Documentation](https://paolino.github.io/cardano-node-clients/)**

## Features

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **Balance** -- exact-fee transaction balancing plus fee-dependent output convergence
- **TxBuild** -- Conway-era transaction builder DSL with `Peek`, `Ctx`, and `Valid`
- **N2C** -- LocalStateQuery + LocalTxSubmission over Unix socket

## Executables

- [`utxo-indexer`](app/utxo-indexer/) -- in-memory address->UTxO indexer
  daemon exposing NDJSON snapshot/await over a Unix socket.
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
```

## License

[Apache-2.0](LICENSE)
