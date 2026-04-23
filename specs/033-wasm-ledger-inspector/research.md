# Phase 0 Research: WASM Conway Tx Inspector + Nix Module

**Feature**: 033-wasm-ledger-inspector
**Date**: 2026-04-23
**Scope**: Resolve all technical unknowns before design. All decisions below flow from the research summary already captured in the parent issue (`lambdasistemi/cardano-node-clients#68`) and the `haskell-wasm` / `nix` skills.

---

## Decision 1 — WASM toolchain

- **Decision**: GHC 9.12 via `ghc-wasm-meta` targeting `wasm32-wasi`, invoked from a `nix shell 'gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org#all_9_12'` environment.
- **Rationale**: GHC 9.12.1 is the first version where Template Haskell on the WASM backend works end-to-end ([Tweag 2024-11 blog post](https://www.tweag.io/blog/2024-11-21-ghc-wasm-th-ghci/)). TH is pervasive in the ledger / Plutus dependency closure; anything earlier would require dodging TH in packages we don't own. IntersectMBO's `cardano-wasm` sub-package uses this exact toolchain and compiles the ledger closure successfully, which validates the choice.
- **Alternatives considered**:
  - GHC-JS backend. Produces JavaScript, not WASM. Fine for browser-only consumers but eliminates server-side WASI runtimes (`wasmtime`, embedded wallets). Kept as a future follow-up; not required for this feature.
  - `asterius`. Superseded by the upstream GHC WASM backend; no longer actively developed.
  - Rust-based re-implementation (e.g. `cardano-serialization-lib`). Explicitly rejected in the issue — re-encodes CBOR, loses byte fidelity, does not share the decoder the Haskell ecosystem trusts.

## Decision 2 — Cabal-wasm override set source

- **Decision**: Vendor the `if arch(wasm32)` stanza from IntersectMBO `cardano-api` master (`cardano-api/cabal.project`) as the first-iteration override set, with pins recorded in `nix/wasm/forks.json` under our own control.
- **Rationale**: IntersectMBO's `cardano-wasm` sub-package ([`IntersectMBO/cardano-api/tree/master/cardano-wasm`](https://github.com/IntersectMBO/cardano-api/tree/master/cardano-wasm)) compiles the exact ledger closure we need with green CI on 2026-04-22. The override set is empirically validated. Copying it eliminates weeks of per-blocker discovery. Pinning to specific fork revisions (rather than tracking IntersectMBO master) insulates us from upstream churn and satisfies FR-003 (vendored pins).
- **Alternatives considered**:
  - Track IntersectMBO `cardano-api` as a flake input. Rejected: adds a runtime dep on cardano-api's full closure (FR-019 forbids it), and couples our build to their branch movements.
  - Hand-write a Conway mini-decoder to dodge the full override set. Rejected earlier in the design loop: saves no meaningful complexity because `cardano-ledger-conway` re-exports `TxInfo` backed by `plutus-ledger-api`, and re-implementing a CBOR decoder for tx bodies is a long-running maintenance tax tracking Conway evolution.

## Decision 3 — Override set contents (concrete)

- **Decision**: First-iteration `forks.json` contains the following entries, mirroring IntersectMBO's working stanza. Each entry records upstream URL, pinned commit SHA, and nix32 SHA256.
  - `plutus` → IntersectMBO fork (flag `+do-not-build-plutus-exec`) covering the 32-bit safety work pending in [IntersectMBO/plutus#7362](https://github.com/IntersectMBO/plutus/pull/7362).
  - `hs-memory` → `haskell-wasm/hs-memory` (replaces archived `memory`/`basement`/`foundation`).
  - `cborg` → `amesgen/cborg` fork (patches `GHC.IntWord64` removal on 32-bit).
  - `network` → `haskell-wasm/network` fork (WASI shim).
  - `double-conversion` → `palas/double-conversion` fork (C++ arch detection).
  - `criterion-measurement` → `palas/criterion` fork.
  - `haskell-lmdb-mock` → `palas/haskell-lmdb-mock` (replaces LMDB's pthreads closure with a mock; acceptable because the inspector does not persist state).
  - `foundation` → `Jimbo4350/foundation` fork.
- **Cabal flags / package stanzas** (written into `cabal-project-fragment.nix`):
  - `package cardano-crypto-praos`: `flags: -external-libsodium-vrf` (compile libsodium VRF as cbits).
  - `package crypton`: `ghc-options: -optc-DARGON2_NO_THREADS`.
  - `package digest`: `flags: -pkg-config` (WASI SDK has no system zlib).
  - `package atomic-counter`: `flags: +no-cmm`.
  - `allow-newer: *:template-haskell, *:base, *:deepseq, *:ghc-prim, *:time, *:text`.
  - `constraints: time installed`.
  - `package ram`: `-optc-D_WASI_EMULATED_MMAN -optl-lwasi-emulated-mman` (per the `haskell-wasm` skill — `ram` replaces `memory`).
- **Rationale**: Each entry addresses a specific, known-cause blocker documented in the `haskell-wasm` skill or in the IntersectMBO `cabal.project`. The exhaustive list is the minimum needed for the ledger closure.
- **Alternatives considered**: Omitting individual entries and fixing breakage reactively — rejected because this produces long, error-driven cycles; we prefer to copy the full working set and remove entries only after proving they're unneeded.

## Decision 4 — Deterministic packaging pattern

- **Decision**: Two-phase FOD per the `haskell-wasm` skill:
  1. **Phase 1 (fixed-output)**: truncate the Hackage `01-index.tar.gz` to a pinned `index-state`, bootstrap `cabal` with a deterministic local Hackage repo, populate the cabal store.
  2. **Phase 2 (regular derivation)**: build `wasm32-wasi-cabal build <target>` offline against the cached store.
- **Rationale**: `cabal update` is non-deterministic (index grows daily); GHC WASM compilation is non-deterministic across machines. The two phases separate these concerns so each can be content-addressed correctly. This is the pattern the `cardano-addresses` branch (`paolino/cardano-addresses#001-wasm-target`) uses successfully.
- **Details captured**:
  - `index-state` set to one day before the pinned truncation date to avoid timestamp-boundary flaps.
  - `root-keys: aaa` + `key-threshold: 0` to bypass cabal's built-in bootstrap key requirement.
  - `CABAL_DIR` set explicitly in the regular derivation so `wasm32-wasi-cabal` picks up the bootstrapped store.
  - `cp -rL` + `chmod -R u+w` to dereference symlinks from `dotCabal`.
  - Store-path sanitization: no asciinema or log files in the repo contain store hashes (documented in the plan's Risks section).
- **Alternatives considered**:
  - Single FOD for the whole build — rejected: GHC WASM compile step is non-deterministic, would break the FOD hash check.
  - Regular derivation with `impure` network access — rejected: fails in sandboxed CI and violates reproducibility goals.

## Decision 5 — Ledger packages in scope

- **Decision**: The first-cut builder accepts any subset of `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`. Downstream consumers may pass any combination; the inspector demo depends on all three.
- **Rationale**: The inspector needs Conway tx body decoding (requires `cardano-ledger-conway`), era-aware schema (`cardano-ledger-api`), and CBOR primitives (`cardano-ledger-binary`). `cardano-ledger-conway` transitively pulls `plutus-ledger-api` — confirmed unavoidable by the Phase 0 investigation summarized in issue #68. The override set accommodates the Plutus closure.
- **Out of scope**: `cardano-api`, `ouroboros-consensus`, `cardano-node`. These have their own WASM blockers and the feature's goal is a ledger-only module, not a full node toolkit.
- **Alternatives considered**: A narrower scope targeting only `cardano-ledger-binary` — rejected because MPFS (the immediate downstream consumer) needs Conway types; shipping only binary forces every consumer to re-derive the Conway bits.

## Decision 6 — Inspector output schema

- **Decision**: Structural JSON with the following top-level keys (details in `data-model.md`): `inputs`, `reference_inputs`, `mint`, `outputs`, `redeemers`. Lossy by design; not round-trippable; field ordering stable for golden comparisons.
- **Rationale**: Matches FR-007 / FR-008 exactly and covers the fields `cardano-mpfs-offchain#227` needs for proof-to-tx binding. A richer schema (full round-trippable tx) would multiply the maintenance cost against Conway evolution without serving a known consumer.
- **Alternatives considered**:
  - Full round-trip CBOR → JSON → CBOR. Rejected: the point of the inspector is inspection, not serialization; re-encoding invites bugs (cf. `cardano-serialization-lib`).
  - Plutus `Data` only. Rejected: MPFS needs input/output addresses and values, not just Plutus data.

## Decision 7 — Browser runtime & docs framework

- **Decision**: `@bjorn3/browser_wasi_shim@0.4.2` for the browser side of the inspector. MkDocs + mkdocs-material via `paolino/dev-assets/mkdocs` flake input. GitHub Pages for deployment (standard across the user's project family).
- **Rationale**:
  - `browser_wasi_shim` is the reference WASI shim used by the `haskell-wasm` skill and already consumed by sibling projects.
  - `paolino/dev-assets/mkdocs` centralizes mkdocs-material + mermaid2 + plugin pinning; no per-repo `pip install` or `npm install`.
  - GitHub Pages matches the existing delivery model for the user's other docs sites.
- **Alternatives considered**:
  - `wasmer-js` / other shims. Rejected: more surface area, less skill coverage.
  - Docusaurus / Astro. Rejected: diverges from the standard stack in sibling projects; MkDocs already covers the demo's needs.

## Decision 8 — Test fixtures sourcing

- **Decision**: Copy three Conway tx CBOR hex fixtures (boot, request-insert, update) from `cardano-mpfs-offchain` E2E into `test/fixtures/conway/` as committed bytes. Generate `expected.json` once by running the inspector native, hand-review against the ledger's own structure (via `ghci` or a quick Haskell script), then commit.
- **Rationale**:
  - Committed fixtures keep tests hermetic — no network, no dependency on the MPFS repo at build time.
  - Three fixtures cover the distinct endpoint shapes (state datum, request datum, trie-touch) that matter for MPFS's proof binding — the feature's primary downstream consumer.
  - Hand-reviewed golden JSON catches regressions when `cardano-ledger-conway` bumps.
- **Licensing note**: `cardano-mpfs-offchain` and this repo share the same project owner; fixture bytes are derivative of on-chain data (public by construction). No license conflict.
- **Alternatives considered**:
  - Generate fixtures at build time from MPFS E2E — rejected: adds build-time dependency on the MPFS repo, defeats hermetic testing.
  - QuickCheck-generated fixtures — rejected as primary strategy because the decoder's correctness is what we're testing; QuickCheck is better as a follow-up for edge cases.

## Decision 9 — Flake topology

- **Decision**: Follow the `/nix` skill's `nix/` layout: `project.nix` (haskell.nix cabalProject'), `checks.nix` (library, exe, tests, lint), `apps.nix` (runnable wrappers over checks). WASM additions live under `nix/wasm/` as a sibling module and are wired into `packages.<sys>.wasm-tx-inspector`, `packages.<sys>.docs-site`, `checks.<sys>.*`, `apps.<sys>.{serve-docs,deploy-docs}`. Existing N2C client flake outputs untouched.
- **Rationale**: Respects the established repo convention and keeps WASM scope isolated. Downstream consumers import `lib.wasm` explicitly; they never accidentally pull it.
- **Alternatives considered**: Mixing WASM outputs into the existing `nix/project.nix` — rejected: harder to reason about, violates the skill's separation of concerns.

## Decision 10 — CI shape

- **Decision**: Two GitHub Actions workflows:
  - `haskell-wasm.yml`: on every push, build `.#checks.<sys>.{wasm-smoke, wasm-tx-inspector, wasm-tx-inspector-tests, docs-site, lint}` via `paolino/dev-assets/setup-nix@v0.0.1`.
  - `deploy-docs.yml`: on `main` only, depends on `haskell-wasm.yml` success; builds `packages.<sys>.docs-site` and publishes to GitHub Pages.
- **Rationale**: Matches the workflow skill's nix-first CI pattern. Single source of truth (checks); apps wrap them. Build-gate before deploy protects FR-015.
- **Alternatives considered**: Running `cabal build` directly in CI — rejected: the workflow skill mandates `nix develop -c just ci`; deviating would break the "same environment everywhere" invariant.

---

## Clarifications resolved

No `NEEDS CLARIFICATION` markers remain. FR-020 was resolved during `/speckit.specify` (inspector + docs live in this repo; constitution amended with Principle V). All other technical unknowns are addressed by the decisions above.
