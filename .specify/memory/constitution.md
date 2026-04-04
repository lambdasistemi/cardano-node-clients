# Cardano Node Clients Constitution

## Core Principles

### I. Channel-Driven N2C Clients
All node communication is via Ouroboros mini-protocols over Unix sockets. Clients are record-of-functions parameterized by channels (LSQChannel, LTxSChannel). ChainSync is a separate connection.

### II. Devnet E2E Testing
The devnet library provides `withCardanoNode` for spinning up a local node with genesis files. E2E tests run against real nodes, not mocks.

### III. Minimal Dependencies
This is an infrastructure library. Depend on cardano-ledger and ouroboros-network, chain-follower for the Follower abstraction. No application-specific types.

### IV. Test Utilities Are First-Class
Test helpers (devnet, genesis keys, transaction building) are exported as public libraries so downstream packages can use them.

## Quality Gates

- `just ci` passes (build, e2e, format, hlint)
- All E2E tests run against a real devnet node
- No mocks for node communication

## Development Workflow

- Nix-first: all tools from `nix develop`
- Fourmolu formatting
- Linear git history via rebase merge

**Version**: 1.0.0 | **Ratified**: 2026-04-02
