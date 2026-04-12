# Tasks: Mainnet TxBuild Golden Vectors

- [x] Commit the 12 mainnet CBOR-hex fixtures to the repository.
- [x] Add a dedicated unit spec for mainnet golden vectors.
- [x] Decode fixtures into `Tx ConwayEra` where the ledger decoder accepts the payload.
- [x] Reconstruct the supported transaction structure with `TxBuild`.
- [x] Compare the reconstructed transactions against the decoded fixtures.
- [x] Wire the spec into the unit test suite.
- [x] Run the unit tests and fix any coverage gaps exposed by real vectors.
- [ ] Resolve the `17a8e607...` Indigo stability fixture, which Blockfrost serves in a form rejected by `cardano-ledger` decoders v9-v11.
