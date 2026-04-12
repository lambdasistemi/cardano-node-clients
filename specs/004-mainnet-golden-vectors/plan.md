# Implementation Plan: Mainnet TxBuild Golden Vectors

## Summary

Add an offline unit-test harness that decodes committed Conway-era mainnet transaction fixtures, reconstructs their supported structure with `TxBuild`, and checks structural equivalence for the fields the DSL currently owns.

## Technical Approach

1. Commit fixture files under `test/fixtures/mainnet-txbuild/`.
2. Add a new unit spec dedicated to mainnet golden vectors.
3. Decode fixtures with `Cardano.Ledger.Binary.decodeFullAnnotatorFromHexText`.
4. Reconstruct each transaction by translating decoded fields into `TxBuild` instructions.
5. Compare only supported fields:
   - inputs
   - collateral inputs
   - reference inputs
   - outputs
   - mint
   - withdrawals
   - required signers
   - validity interval
   - metadata
   - witness scripts
   - redeemer purposes, indices, and data
6. Explicitly ignore unsupported or build-dependent fields:
   - fee
   - signatures
   - datum witnesses
   - ExUnits
   - script integrity hash

## Risks

- Some vectors may expose a TxBuild gap not reflected in issue text.
- Real transactions can include witness details that the DSL intentionally does not reconstruct today; the comparison must stay scoped.

## Verification

- Run `cabal test unit-tests` inside `nix develop`.
