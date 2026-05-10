# cardano-node-clients Development Guidelines

Auto-generated from feature plans. Last updated: 2026-05-10

## Active Technologies

- Haskell, GHC2021
- Cabal multi-component package
- Nix development environment
- Cardano ledger and Plutus libraries

## Project Structure

```text
lib/              # main cardano-node-clients library
lib-utxo-indexer/ # UTxO indexer sublibrary
e2e-test/         # devnet helper library
app/              # executables
test/             # unit and e2e test modules
specs/            # Spec Kit feature artifacts
```

## Commands

```bash
just build
just unit
just e2e
just format
just hlint
just ci
```

Use focused Cabal commands with `-O0` while iterating.

## Code Style

- Follow the repo's Fourmolu formatting.
- Keep component dependencies minimal and explicit.
- Preserve existing public module compatibility unless a spec says
  otherwise.

## Recent Changes

- `041-extract-txbuild`: planned extraction of TxBuild and Balance into
  a non-network transaction-building component.

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
