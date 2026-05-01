# cardano-node-clients-tx-builder Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-05-01

## Active Technologies
- Haskell, GHC 9.6+ (matches repo). (034-cardano-tx-generator)
- two files in `--state-dir` (`master.seed` 32 bytes, (034-cardano-tx-generator)
- Haskell, GHC 9.6+ (matches repo) + `cardano-ledger-conway`, `ouroboros-network`, internal `chain-follower` `Follower` abstraction, internal `N2C.Reconnect.runReconnectLoop` (PR #105) (037-tx-gen-indexer-fresh)
- in-memory `TVar ReadyState` (no persistence change) (037-tx-gen-indexer-fresh)

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
- 037-tx-gen-indexer-fresh: Added Haskell, GHC 9.6+ (matches repo) + `cardano-ledger-conway`, `ouroboros-network`, internal `chain-follower` `Follower` abstraction, internal `N2C.Reconnect.runReconnectLoop` (PR #105)
- 034-cardano-tx-generator: Added Haskell, GHC 9.6+ (matches repo).

- 003-tx-builder-dsl: Added Haskell (GHC 9.6+, same as cardano-node-clients) + cardano-ledger-api, cardano-ledger-conway, plutus-ledger-api, plutus-tx (ToData/FromData)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
