# Repository Agent Guide

## What this repo is

`cardano-node-clients` is a Haskell package (Cabal multi-component,
built with Nix/haskell.nix) of channel-driven clients for the Cardano
node Ouroboros mini-protocols. It provides N2C LocalStateQuery,
LocalTxSubmission, and ChainSync clients over the node's Unix socket,
high-level `Provider`/`Submitter` record-of-functions interfaces, a
reconnect supervisor with an LSQ tip probe, a layered indexer stack
(generic `block-indexer`, address-keyed UTxO indexer, multi-tenant
tx-history indexer), and an N2N adversary for fault-injection testing.
It ships two executables: the `utxo-indexer` daemon and the
`cardano-adversary` daemon. Transaction building/balancing/diffing
lives in a separate repo,
[cardano-tx-tools](https://github.com/lambdasistemi/cardano-tx-tools).

## How to work here

All commands run inside the Nix dev shell; `just` recipes pin `-O0`.

- Build: `nix develop -c just build` (library + both executables)
- Unit tests: `nix develop -c just unit`
- E2E tests (spawns a real devnet `cardano-node`): `nix develop -c just e2e`
- Format: `nix develop -c just format` (fourmolu + cabal-fmt)
- Lint: `nix develop -c just hlint`
- Full gate: `nix develop -c just ci` (build + unit + format check + lint)
- Docs preview: `nix develop -c just serve-docs`
- Run an executable: `nix run .#utxo-indexer` / `nix run .#cardano-adversary`

GHC is pinned to `ghc9123` by the flake; the package is `GHC2021`.
Public modules must keep Haddock on exports and Apache-2.0 module
headers. Do not break existing public module compatibility without a
spec.

## Skills

Activatable procedures live under `skills/`. Load the one whose
description matches your task:

- `skills/cardano-node-clients-guide/` — repository map, exact
  build/test/run commands, where each feature lives in the source,
  verified CLI/library usage, and where answers to common questions
  live.

## Documentation

- Human docs: <https://lambdasistemi.github.io/cardano-node-clients/>
  (sources under `docs/`, built with mkdocs).
- README.md — overview, install, quickstart, usage.
- `app/utxo-indexer/README.md` — the indexer daemon's CLI and wire.
- `specs/` — Spec Kit feature artifacts (one dir per feature).
