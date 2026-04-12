# Tasks: Mainnet TxBuild Golden Vectors

- [x] Commit the selected Conway-era mainnet CBOR-hex fixtures to the repository.
- [x] Commit offline input-value fixtures for each golden transaction's consumed body inputs.
- [x] Add a dedicated unit spec for mainnet golden vectors.
- [x] Decode fixtures into `Tx ConwayEra` where the ledger decoder accepts the payload.
- [x] Reconstruct the supported transaction structure with `TxBuild`.
- [x] Compare the reconstructed transactions against the decoded fixtures in a `draft` conformance pass.
- [x] Replay original `ExUnits` and run a `build` pass that balances against the committed input-value fixtures.
- [x] Compare the built transactions against the decoded fixtures while allowing one appended change output and a recomputed fee.
- [x] Wire the spec into the unit test suite.
- [x] Run the unit tests and fix any coverage gaps exposed by real vectors.
- [x] Remove the pre-Conway `17a8e607...` Indigo stability vector from the Conway-only suite.
