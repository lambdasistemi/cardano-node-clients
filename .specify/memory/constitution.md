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

### VI. Ledger Functional Layer and Data Boundary
Ledger-facing browser demos and downstream applications MUST model user-visible work as explicit transaction documents in application/workspace state. The canonical transaction state is CBOR bytes owned by that workspace, not hidden mutable state inside a WASM instance.

Haskell/WASM ledger components MUST behave as a ledger functional layer: each operation receives the current transaction CBOR, explicit operation arguments, and any external ledger context required for reproducibility; each operation returns a JSON result and, for mutating operations, the resulting transaction CBOR. WASM code MAY cache decoded values or handles for performance, but cached state MUST NOT be the source of truth and MUST NOT make operation results depend on unobserved prior calls.

JSON is the control plane for operation names, paths, diagnostics, summaries, and simple arguments. CBOR is the data plane for transactions and fidelity-sensitive ledger values. Structural JSON is a view over ledger data, not a round-trippable ledger serialization. Provider or chain state MAY enter an operation only through explicit request context or an explicitly named provider fetch, so results can be reproduced from captured inputs.

## Quality Gates

- `just ci` passes (build, e2e, format, hlint)
- All E2E tests run against a real devnet node
- No mocks for node communication
- Demo subtrees build under their target toolchain (e.g. wasm32-wasi) and their fixture-based tests pass in CI
- Ledger operation interfaces preserve CBOR as the canonical transaction state and expose JSON only as an operation/view contract

## Development Workflow

- Nix-first: all tools from `nix develop`
- Fourmolu formatting
- Linear git history via rebase merge

**Version**: 1.2.0 | **Ratified**: 2026-04-02 | **Amended**: 2026-04-25 (added Principle VI for the ledger functional layer, workspace-owned transaction state, and JSON-control/CBOR-data boundary)
