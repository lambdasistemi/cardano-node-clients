# Implementation Plan: Expand TxBuild Golden Vectors

## Summary

Reuse the existing Conway-era golden harness from issue `#43`, then extend the committed fixture set with one new Splash vector, one new oracle vector, and one new Strike Finance vector chosen from public Cardano registries and verified against the existing `draft` plus offline `build` checks.

## Technical Approach

1. Use Cardano's public app directory and transaction-ranking methodology to justify the protocol-family choices.
2. Use the public CRFA off-chain registry to resolve concrete script hashes and script addresses for Splash, Strike Finance, and Charli3.
3. Query Koios for real Conway-era transactions that touch those documented script addresses.
4. Prefer candidate transactions that consume the documented script address, not just create an output at it.
5. Fetch committed CBOR-hex fixtures and consumed-input lovelace fixtures for the selected transaction hashes.
6. Extend `TxBuildGoldenSpec` with protocol-specific case names:
   - Splash order v3
   - Strike perps LP
   - Charli3 oracle v9
7. Run the existing `draft` and offline `build` golden checks unchanged.
8. Update the issue and PR text with the exact hashes, timestamps, registry entries, and rationale.

## Risks

- A transaction found via a documented script address can still be a poor golden vector if it uses unsupported fields or fails the existing build constraints.
- Registry entries identify protocol contracts, but they do not classify every mainnet transaction automatically; the final selection still requires judgment.

## Verification

- Run targeted `unit-tests` for the three new cases.
- Run full `unit-tests` after the suite is updated.
