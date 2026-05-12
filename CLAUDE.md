# cardano-node-clients-tx-builder Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-05-12

## Active Technologies
- Haskell, GHC 9.6+ (matches repo). (034-cardano-tx-generator)
- two files in `--state-dir` (`master.seed` 32 bytes, (034-cardano-tx-generator)
- Haskell, GHC 9.6+ (matches repo) + `cardano-ledger-conway`, `ouroboros-network`, internal `chain-follower` `Follower` abstraction, internal `N2C.Reconnect.runReconnectLoop` (PR #105) (037-tx-gen-indexer-fresh)
- in-memory `TVar ReadyState` (no persistence change) (037-tx-gen-indexer-fresh)
- Haskell, GHC 9.12.2 (matches existing flake-pinned toolchain). + `cardano-ledger-conway` (1.21), `cardano-ledger-babbage` (1.13, supplies `totalCollateralTxBodyL` / `collateralReturnTxBodyL`), `cardano-ledger-alonzo` (supplies `ppCollateralPercentageL`), `cardano-ledger-api` (`estimateMinFeeTx`). All are already in the closure. (040-txbuild-conway-collateral)
- N/A — pure tx assembly; no persistence change. (040-txbuild-conway-collateral)
- Haskell, GHC pinned by `cabal.project` (current + `cardano-ledger-conway`, `cardano-ledger-api`, (042-conway-stake-treasury)
- N/A. DSL is pure; produces a `ConwayTx` for submission. (042-conway-stake-treasury)

- Haskell (GHC 9.6+, same as cardano-node-clients) + cardano-ledger-api, cardano-ledger-conway, plutus-ledger-api, plutus-tx (ToData/FromData) (003-tx-builder-dsl)

## Project Structure

```text
src/
tests/
```

## Commands

# Add commands for Haskell (GHC 9.6+, same as cardano-node-clients)

## Code Style

Haskell (GHC 9.6+, same as cardano-node-clients): Follow standard conventions

## Recent Changes
- 042-conway-stake-treasury: Added Haskell, GHC pinned by `cabal.project` (current + `cardano-ledger-conway`, `cardano-ledger-api`,
- 040-txbuild-conway-collateral: Added Haskell, GHC 9.12.2 (matches existing flake-pinned toolchain). + `cardano-ledger-conway` (1.21), `cardano-ledger-babbage` (1.13, supplies `totalCollateralTxBodyL` / `collateralReturnTxBodyL`), `cardano-ledger-alonzo` (supplies `ppCollateralPercentageL`), `cardano-ledger-api` (`estimateMinFeeTx`). All are already in the closure.
- 037-tx-gen-indexer-fresh: Added Haskell, GHC 9.6+ (matches repo) + `cardano-ledger-conway`, `ouroboros-network`, internal `chain-follower` `Follower` abstraction, internal `N2C.Reconnect.runReconnectLoop` (PR #105)


<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
