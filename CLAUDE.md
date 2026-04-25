# cardano-node-clients-tx-builder Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-04-23

## Active Technologies
- Haskell GHC 9.12.1+ for the WASM path (`wasm32-wasi-ghc` from `ghc-wasm-meta`); existing repository GHC pin untouched for native artifacts. + `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`, `plutus-ledger-api` (transitive through Conway); Nix tooling via `haskell.nix`, `ghc-wasm-meta`, `paolino/dev-assets/mkdocs`; browser shim `@bjorn3/browser_wasi_shim@0.4.2`. (033-wasm-ledger-inspector)
- N/A — decoder is stateless. (033-wasm-ledger-inspector)

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
- 033-wasm-ledger-inspector: Added Haskell GHC 9.12.1+ for the WASM path (`wasm32-wasi-ghc` from `ghc-wasm-meta`); existing repository GHC pin untouched for native artifacts. + `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`, `plutus-ledger-api` (transitive through Conway); Nix tooling via `haskell.nix`, `ghc-wasm-meta`, `paolino/dev-assets/mkdocs`; browser shim `@bjorn3/browser_wasi_shim@0.4.2`.

- 003-tx-builder-dsl: Added Haskell (GHC 9.6+, same as cardano-node-clients) + cardano-ledger-api, cardano-ledger-conway, plutus-ledger-api, plutus-tx (ToData/FromData)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
