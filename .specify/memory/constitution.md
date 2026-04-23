# Cardano Node Clients Constitution

## Core Principles

### I. Channel-Driven N2C Clients
All node communication is via Ouroboros mini-protocols over Unix sockets. Clients are record-of-functions parameterized by channels (LSQChannel, LTxSChannel). ChainSync is a separate connection.

### II. Devnet E2E Testing
The devnet library provides `withCardanoNode` for spinning up a local node with genesis files. E2E tests run against real nodes, not mocks.

### III. Minimal Dependencies
This is an infrastructure library. Depend on cardano-ledger and ouroboros-network, chain-follower for the Follower abstraction. No application-specific types in the library surface.

### IV. Test Utilities Are First-Class
Test helpers (devnet, genesis keys, transaction building) are exported as public libraries so downstream packages can use them.

### V. Demo Infrastructure Carve-Out
This repository MAY host application-shaped artifacts whose sole purpose is to exercise and showcase this repository's own infrastructure (Nix modules, flake outputs, cross-compilation toolchains, build helpers). Such artifacts MUST live under a clearly-named subtree (e.g. `wasm-apps/`, `demos/`) and MUST be excluded from the library's public API surface. They exist to prove the infrastructure works end-to-end and to give downstream consumers a reference implementation; they are not product. Principle III applies to the library, not to demo subtrees.

## Quality Gates

- `just ci` passes (build, e2e, format, hlint)
- All E2E tests run against a real devnet node
- No mocks for node communication
- Demo subtrees build under their target toolchain (e.g. wasm32-wasi) and their fixture-based tests pass in CI

## Development Workflow

- Nix-first: all tools from `nix develop`
- Fourmolu formatting
- Linear git history via rebase merge

**Version**: 1.1.0 | **Ratified**: 2026-04-02 | **Amended**: 2026-04-23 (added Principle V to carve out demo infrastructure for the WASM ledger inspector)
