# Tasks: Mainnet TxBuild Golden Vectors

- [x] Commit the selected Conway-era mainnet CBOR-hex fixtures to the repository.
- [x] Add a dedicated unit spec for mainnet golden vectors.
- [x] Decode fixtures into `Tx ConwayEra` where the ledger decoder accepts the payload.
- [x] Reconstruct the supported transaction structure with `TxBuild`.
- [x] Compare the reconstructed transactions against the decoded fixtures.
- [x] Wire the spec into the unit test suite.
- [x] Run the unit tests and fix any coverage gaps exposed by real vectors.
- [x] Remove the pre-Conway `17a8e607...` Indigo stability vector from the Conway-only suite.
