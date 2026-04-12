# Implementation Plan: Mainnet TxBuild Golden Vectors

## Summary

Add an offline unit-test harness that decodes committed Conway-era mainnet transaction fixtures, reconstructs their supported structure with `TxBuild`, and checks both `draft`-level conformance and `build`-level balancing against committed historical input values.

## Technical Approach

1. Commit fixture files under `test/fixtures/mainnet-txbuild/`, including per-transaction input-value fixtures for consumed body inputs.
2. Add a new unit spec dedicated to mainnet golden vectors.
3. Decode fixtures with `Cardano.Ledger.Binary.decodeFullAnnotatorFromHexText`.
4. Reconstruct each transaction by translating decoded fields into `TxBuild` instructions.
5. Run a `draft` pass and compare only supported fields:
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
6. Run a `build` pass with representative Conway fee parameters, the committed input-value fixtures, and replayed original `ExUnits`.
7. Compare the built transaction against the decoded fixture while allowing exactly one appended change output and a recomputed fee.
8. Explicitly ignore unsupported or non-goal fields:
   - fee
   - signatures
   - datum witnesses
   - script integrity hash

## Risks

- Some vectors may still fail to balance if the representative Conway fee parameters exceed the historical fee budget.
- Real transactions can include witness details that the DSL intentionally does not reconstruct today; the comparison must stay scoped.
- Replayed `ExUnits` strengthen the build claim, but they are not a replacement for live chain evaluation.

## Verification

- Run `cabal test unit-tests` inside `nix develop`.
