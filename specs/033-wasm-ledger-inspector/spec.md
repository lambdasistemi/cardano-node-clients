# Feature Specification: WASM Conway Tx Inspector + Vendored Cardano-Ledger WASM Nix Module + MkDocs Live Demo

**Feature Branch**: `033-wasm-ledger-inspector`
**Created**: 2026-04-23
**Status**: Draft
**Input**: User description: "WASM Conway tx inspector plus vendored cardano-ledger WASM Nix module with MkDocs live demo"
**Related**: lambdasistemi/cardano-node-clients#68

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Downstream flake cross-compiles a ledger subset to WASM (Priority: P1)

A downstream Haskell project (starting with the MPFS client verifier) needs to cross-compile a chosen slice of the `cardano-ledger-*` package family to `wasm32-wasi` so the same verifier logic can run in a browser, Node, or embedded-wallet runtime. Today this is blocked because the ledger's transitive closure contains packages that do not build unchanged for WASM (archived `basement`/`foundation`, `cborg` importing a removed GHC module on 32-bit, Plutus 32-bit integer safety, C dependencies that need cbits rather than dynamic linking, etc.). A consumer should be able to add a single flake input and get a working WASM build without having to discover, fork, and pin every workaround themselves.

**Why this priority**: This is the foundational, reusable piece. Everything else in this feature consumes it. Without it the other deliverables cannot exist, and more importantly: unblocking other repos (MPFS client, future wallet work) is the actual business motivation.

**Independent Test**: A throwaway downstream flake (inside or outside this repo) imports the module, declares a trivial Haskell library that depends on `cardano-ledger-binary` and `cardano-ledger-conway`, and successfully builds it for `wasm32-wasi`. Success is one green `nix build`; no hand-editing of `cabal.project`, no discovery of fork pins, no per-consumer patches.

**Acceptance Scenarios**:

1. **Given** a fresh checkout of a downstream flake that imports this module as a flake input, **When** the downstream declares a haskell.nix project depending on `cardano-ledger-api` + `cardano-ledger-binary` + `cardano-ledger-conway`, **Then** `nix build` produces a `.wasm` artifact that loads under `wasmtime` without relinking or external patches.
2. **Given** the same downstream, **When** the flake is evaluated on a machine that has never built it before, **Then** the build is fully reproducible from a deterministic Hackage index snapshot and a pinned set of source-repository-package forks, with no network access during the compilation phase.
3. **Given** a consumer that only needs `cardano-ledger-binary` (not Conway, not Plutus), **When** they invoke the module's builder with that narrower package set, **Then** the resulting derivation compiles the smaller closure and does not force unused Plutus packages into the build graph.

---

### User Story 2 — Reviewer inspects a Conway tx body in the browser without installing anything (Priority: P2)

Someone reviewing a Cardano transaction — a protocol designer, an auditor, an MPFS integrator, a wallet developer — needs to see the structural contents of a Conway-era transaction (inputs, reference inputs, mint, outputs with addresses / values / datum shape, redeemers) starting from raw CBOR hex. Today this requires either installing a Cardano CLI toolchain, writing Haskell against `cardano-api`, or using one of the Rust-based WASM libraries which re-encode CBOR and can silently change bytes. The reviewer wants to paste hex into a web page and see the decoded structure, with the same decoder the Haskell ecosystem already trusts.

**Why this priority**: This is the first concrete consumer of User Story 1's module and proves the module works end-to-end. It is also the shortest path to a visible artifact that demonstrates the whole stack is real.

**Independent Test**: Given a known Conway tx hex (sourced from MPFS E2E fixtures: boot, request-insert, update), the inspector run under `wasmtime` emits JSON whose `inputs`, `reference_inputs`, `mint`, `outputs`, and `redeemers` arrays match the ledger's own interpretation of those bytes. The same artifact, loaded in a browser via a standard WASI shim, produces byte-identical output for the same input.

**Acceptance Scenarios**:

1. **Given** a valid Conway tx CBOR hex on stdin, **When** the inspector runs under `wasmtime`, **Then** stdout contains a JSON object with the five structural arrays populated according to the tx body contents.
2. **Given** the same hex pasted into the browser demo, **When** the page decodes it, **Then** the displayed JSON is byte-identical to the `wasmtime` output.
3. **Given** a malformed or non-Conway CBOR input, **When** the inspector runs, **Then** it exits with a non-zero status and an error message naming the decoding failure, without producing partial/corrupt JSON.
4. **Given** a tx containing a Plutus datum inside an output, **When** the inspector runs, **Then** the output's `datum` field is present and its shape (inline vs hash, and for inline the `Data` AST rendering) is faithful to the ledger's representation.

---

### User Story 3 — Live demo shipped with the project documentation (Priority: P3)

Anyone who reads this project's documentation — a new contributor, a downstream integrator, a reviewer arriving from the MPFS side — should be able to try the inspector from the docs site itself, in the same place where the module's usage is documented. The demo reinforces the "it really works" claim without requiring the reader to clone anything, and it lives next to the reference material that explains how to consume the module.

**Why this priority**: This layer adds discoverability and credibility, but the underlying capability (User Story 2) is usable on its own even without the docs integration. The demo is valuable but not on the critical path to unblocking downstream consumers.

**Independent Test**: A fresh browser session navigates to the deployed documentation site, opens the inspector page, pastes a Conway tx hex, clicks decode, and sees the JSON output. No local toolchain, no CLI, no prior knowledge of the project.

**Acceptance Scenarios**:

1. **Given** the published documentation site, **When** a reader navigates to the inspector page and submits a known tx hex, **Then** the decoded JSON appears inline within the page.
2. **Given** the documentation source, **When** a contributor runs the local documentation preview, **Then** the inspector page loads and decodes the same fixtures as the deployed site.
3. **Given** a change to the inspector code, **When** the documentation site is rebuilt, **Then** the demo's `.wasm` artifact is refreshed automatically from the flake package; contributors do not hand-copy binaries into the docs directory.

---

### Edge Cases

- What happens when a consumer of the Nix module picks a package combination the override set wasn't validated against (e.g. adds `ouroboros-consensus` which has its own WASM blockers)? The module should surface a clear error about unsupported additional closures rather than silently producing a broken build.
- What happens when a fork pin's upstream is archived, moved, or rewrites history? Vendored pins protect against this by decoupling our build from unpinned upstreams; the module must be structured so a pin update is a single file change.
- What happens when the inspector receives valid CBOR that parses as a non-Conway era tx (e.g. Babbage)? It must fail with an era-mismatch error, not silently decode against the wrong schema.
- What happens when a fixture tx contains a very large datum or redeemer? JSON output must stream or chunk safely; the inspector must not hit WASI memory limits on realistic mainnet-sized bodies.
- What happens when the browser demo runs in a privacy-hardened configuration that blocks WASM? The page should detect and display a readable fallback explaining the required browser capability, not silently hang.
- What happens when the docs site is deployed but the inspector artifact failed to build? The build gate must fail the docs build too; a broken demo must never ship.

## Requirements *(mandatory)*

### Functional Requirements

**Nix module (User Story 1)**

- **FR-001**: The repository MUST expose a flake output that lets a downstream flake import a reusable Nix value providing the full cabal-wasm override set (cabal.project fragment, haskell.nix overlay with vendored source-repository-package forks, and cabal package flags) needed to cross-compile the `cardano-ledger-*` closure to `wasm32-wasi`.
- **FR-002**: The module MUST expose a builder that accepts a caller-chosen set of ledger packages and returns a derivation producing a `.wasm` artifact for those packages, without the caller having to know about individual blockers (Plutus 32-bit safety, archived `basement`/`foundation`, `cborg` on 32-bit, libsodium VRF cbits, crypton pthreads, `digest` zlib, double-conversion architecture detection, LMDB pthreads, `network`).
- **FR-003**: All fork pins MUST be vendored under this repository's control — either as copies of the required patches or as references to forks owned by this project's organization — so the build does not depend on IntersectMBO's `cardano-api` master as a live input.
- **FR-004**: The module MUST produce deterministic WASM artifacts: two invocations of the same `nix build` from the same source inputs MUST produce byte-identical outputs.
- **FR-005**: The module MUST document, inline in code comments or adjacent documentation, which specific Plutus and ledger package versions it targets, what constraints each override addresses, and how a consumer updates a pin.

**Tx inspector (User Story 2)**

- **FR-006**: The repository MUST ship a Haskell executable, built via the Nix module above, that reads a Conway tx CBOR hex on standard input and writes a JSON document on standard output.
- **FR-007**: The JSON document MUST contain keys `inputs`, `reference_inputs`, `mint`, `outputs`, and `redeemers` whose contents reflect the corresponding fields of the Conway tx body as the ledger itself decodes them.
- **FR-008**: For each output, the JSON MUST include address, value (ADA plus multi-asset entries), and datum information (distinguishing no datum / datum hash / inline datum, and rendering the inline datum's structural `Data` AST).
- **FR-009**: The inspector MUST perform no cryptographic validation, script evaluation, fee check, or network access. It is a pure structural decoder.
- **FR-010**: The inspector MUST run unchanged under both a server-side WASI runtime and a browser WASI shim, reading its input and writing its output through the same standard streams.
- **FR-011**: When the input does not parse as a Conway tx, the inspector MUST exit with a non-zero status and emit a single-line error message identifying the failure (era mismatch, malformed CBOR, or structural error), with no partial JSON on stdout.

**MkDocs live demo (User Story 3)**

- **FR-012**: The repository MUST ship a documentation site that includes an interactive page loading the inspector's WASM artifact and exposing a textarea plus a decode button.
- **FR-013**: The demo page MUST pull the inspector artifact from the flake build — the binary embedded in the deployed site MUST be the one produced by the same build that passes the project's checks.
- **FR-014**: The documentation site MUST be buildable locally with the same tooling as the deployed build, such that a contributor's preview reproduces what end users will see.
- **FR-015**: The documentation site MUST be deployed to a public URL when the main branch advances, and the deployment MUST fail if the inspector artifact fails to build.

**Cross-cutting**

- **FR-016**: The repository's existing N2C client library functionality (devnet, chain follower, transaction building) MUST continue to build and its tests MUST continue to pass; the new artifacts MUST not regress existing flake outputs.
- **FR-017**: The project CI MUST run fixture-based tests of the inspector under a server-side WASI runtime on every push, using Conway tx hex fixtures captured from the MPFS end-to-end test suite (boot, request-insert, update at minimum).
- **FR-018**: Every source-repository-package fork referenced by the module MUST have a pinned revision and a content hash recorded alongside it, so the build is reproducible offline.
- **FR-019**: The flake MUST not add a runtime dependency on the IntersectMBO `cardano-api` repository; the override set is informed by cardano-api's precedent but must be self-contained.
- **FR-020**: The tx inspector app and the MkDocs live demo MUST live inside this repository as `wasm-apps/tx-inspector/` and `docs/` subtrees, understood as reference/demo infrastructure whose sole purpose is to exercise and showcase the WASM Nix module shipped by this repository. They are not application functionality of the N2C client library and MUST NOT be treated as such in the project's constitution or in downstream consumers' expectations. A constitution amendment formalizing this carve-out is a prerequisite for `/speckit.plan`.

### Key Entities *(data involved)*

- **Conway transaction body**: the on-chain artifact being decoded — a CBOR-encoded structure containing inputs, reference inputs, outputs, mint, redeemers, and auxiliary fields, as defined by the Conway-era ledger schema.
- **Structural tx JSON**: a lossy, human-oriented projection of the tx body covering only the fields this feature surfaces (inputs, reference inputs, mint, outputs, redeemers). It is not a round-trippable re-encoding.
- **Cabal-wasm override set**: the collection of source-repository-package fork pins, cabal package flags, and `if arch(wasm32)` conditional stanzas needed to make the ledger's transitive closure compile for `wasm32-wasi`.
- **Vendored fork pin**: a reference to a specific revision and content hash of a patched upstream Haskell package, kept under this project's control so the build is independent of upstream branch movements.
- **Documentation site bundle**: the published static artifact (HTML, JS, CSS, WASM) produced by the docs build, including the inspector demo.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A downstream Haskell project can cross-compile a chosen `cardano-ledger-*` subset to `wasm32-wasi` with a single flake input and one `nix build` invocation, with no hand-editing of `cabal.project` and no manual discovery of forks.
- **SC-002**: Given the same source inputs, two independent invocations of `nix build` for the inspector artifact on different machines produce byte-identical `.wasm` outputs.
- **SC-003**: A reviewer who has never seen this project can, starting from a published documentation URL, paste a Conway tx hex and see decoded structural JSON in under 30 seconds, using only a standard modern browser.
- **SC-004**: The decoded JSON for every fixture tx pulled from the MPFS E2E suite (minimum: one boot, one request-insert, one update) matches an expected reference JSON in automated tests, on every push to the main branch.
- **SC-005**: The main branch's documentation deployment succeeds or fails atomically with the inspector build — there is no configuration in which the docs ship with a stale or broken demo.
- **SC-006**: The repository's existing test suite (N2C client functionality, devnet, chain follower) continues to pass at the same level as before this feature lands.
- **SC-007**: The repository continues to build for the native GHC target unchanged after this feature lands; the WASM additions do not disturb the native build path.

## Assumptions

- Downstream consumers of the Nix module are Haskell projects that already use `haskell.nix`; the module is an overlay into that ecosystem, not a self-contained build system.
- The feature targets the Conway ledger era; earlier eras are out of scope for the inspector's era-specific decoding path (though the underlying ledger packages transitively support them).
- Plutus is mandatory in the WASM build: `cardano-ledger-conway` has a hard dependency on `plutus-ledger-api`, so the override set must cover the Plutus closure regardless of whether any specific downstream consumer inspects Plutus data.
- Fixture Conway txs are available from the MPFS end-to-end test suite and can be embedded in this repository's test fixtures under a license compatible with this project.
- The cabal-wasm override set will need periodic maintenance as upstream packages move and as Plutus's 32-bit safety work lands; the feature assumes this is an accepted maintenance cost owned by this repository.
- The documentation site is deployed to GitHub Pages from the main branch; this is the existing delivery model used elsewhere in the user's project family.
- The inspector is a read-only decoder in this feature; constructing, signing, or submitting txs from WASM are out of scope here and tracked separately.
- The feature assumes GHC 9.12.1 or later is used for the WASM build path, because Template Haskell support on the WASM backend landed in that version; the native build path continues to follow the repository's current GHC pin.
