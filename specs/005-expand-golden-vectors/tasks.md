# Tasks: Expand TxBuild Golden Vectors

- [x] Confirm Splash, Strike Finance, and Charli3 are publicly documented in Cardano ecosystem sources.
- [x] Resolve concrete registry-backed script hashes and script addresses for each selected protocol family.
- [x] Find real Conway-era transactions that consume the documented Splash Order Contract v3, Strike Perps LP, and Charli3 Oracle v9 addresses.
- [x] Commit CBOR-hex fixtures for the selected transaction hashes.
- [x] Commit input-value fixtures for the selected transaction hashes.
- [x] Extend `TxBuildGoldenSpec` with protocol-specific golden cases for the three new vectors.
- [x] Verify the three new vectors pass the existing `draft` and offline `build` checks.
- [x] Document the selection rationale in local spec artifacts plus the GitHub issue and PR.
