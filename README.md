# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols (N2C + N2N).

**[Documentation](https://paolino.github.io/cardano-node-clients/)**

## Features

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **Balance** -- exact-fee transaction balancing plus fee-dependent output convergence
- **TxBuild** -- Conway-era transaction builder DSL with `Peek`, `Ctx`, and `Valid`
- **N2C** -- LocalStateQuery + LocalTxSubmission over Unix socket
- **WASM ledger toolkit** -- reusable Nix module for cross-compiling a
  `cardano-ledger-*` subset to `wasm32-wasi`, plus a Conway tx inspector
  demo. See [specs/033-wasm-ledger-inspector/quickstart.md](specs/033-wasm-ledger-inspector/quickstart.md).

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
