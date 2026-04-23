# Implementation Plan: WASM Conway Tx Inspector + Vendored Cardano-Ledger WASM Nix Module + MkDocs Live Demo

**Branch**: `033-wasm-ledger-inspector` | **Date**: 2026-04-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/033-wasm-ledger-inspector/spec.md`

## Summary

Deliver three coupled artifacts in `cardano-node-clients` that together let any downstream Haskell flake cross-compile a chosen `cardano-ledger-*` slice to `wasm32-wasi`, prove the module works end-to-end by shipping a Conway tx inspector built on top of it, and showcase the inspector on the project documentation site as a live in-browser demo. The technical approach is an `haskell.nix` overlay that vendors the `if arch(wasm32)` override set from IntersectMBO's `cardano-wasm` sub-package, a two-phase FOD packaging pattern for deterministic WASM output (truncated Hackage index → bootstrap cabal → offline build), and a MkDocs-material site loading the inspector via `@bjorn3/browser_wasi_shim`. The plan is sliced into P1 (Nix module + builder), P2 (tx inspector app + fixtures), and P3 (MkDocs demo + GitHub Pages deploy), each independently completable.

## Technical Context

**Language/Version**: Haskell GHC 9.12.1+ for the WASM path (`wasm32-wasi-ghc` from `ghc-wasm-meta`); existing repository GHC pin untouched for native artifacts.
**Primary Dependencies**: `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`, `plutus-ledger-api` (transitive through Conway); Nix tooling via `haskell.nix`, `ghc-wasm-meta`, `paolino/dev-assets/mkdocs`; browser shim `@bjorn3/browser_wasi_shim@0.4.2`.
**Storage**: N/A — decoder is stateless.
**Testing**: `wasmtime` against captured Conway tx hex fixtures (boot / request-insert / update from MPFS E2E), expected-JSON golden comparisons; existing repository suites (unit, e2e against devnet node) remain unchanged.
**Target Platform**: `wasm32-wasi` runtime (server-side via `wasmtime`; browser via `browser_wasi_shim`) for the inspector; `x86_64-linux` / `aarch64-darwin` for the flake outputs that host it; GitHub Pages for the docs deploy.
**Project Type**: Haskell infrastructure library (existing) + new WASM cross-compilation toolchain module + new Haskell WASM executable + MkDocs site. Treated in the repo layout as `nix/wasm/` (module), `wasm-apps/tx-inspector/` (demo executable), `docs/` (site) — all carved out under Constitution Principle V.
**Performance Goals**: Deterministic WASM output (byte-identical across machines per SC-002); browser demo renders decoded JSON in ≤30 s on a fresh session (SC-003); native test suite preserved (SC-006/SC-007).
**Constraints**: No runtime dependency on IntersectMBO `cardano-api` (FR-019); fork pins vendored (FR-003); Plutus in scope because `cardano-ledger-conway` forces `plutus-ledger-api`; existing N2C flake outputs untouched (FR-016); CI build-gate must fail the docs deploy when the inspector fails (FR-015).
**Scale/Scope**: First iteration targets three ledger packages + their transitive Plutus closure; fixture set of three Conway txs (one per endpoint class); single-page MkDocs demo; downstream consumer count at launch = 1 (MPFS client) with room to grow.

## Constitution Check

Evaluated against `/memory/constitution.md` v1.1.0.

- **I. Channel-Driven N2C Clients** — Untouched. No changes to the channel abstractions, LSQChannel/LTxSChannel, or ChainSync wiring. The WASM artifacts and MkDocs demo do not participate in node communication.
- **II. Devnet E2E Testing** — Untouched. Existing devnet + `withCardanoNode` harness continues to drive E2E tests against a real node. The WASM inspector is tested offline against captured fixtures; this does not replace or weaken the devnet requirement for the N2C surface.
- **III. Minimal Dependencies** — Respected for the library. The Haskell library that `cardano-node-clients.cabal` exposes gains no new dependencies; the ledger + Plutus closure enters only via the demo subtree `wasm-apps/tx-inspector/` and is compiled only on the WASM path.
- **IV. Test Utilities Are First-Class** — Consistent. The Nix module is itself a first-class utility (a flake output downstream consumers import), mirroring the principle's intent one layer up in the build.
- **V. Demo Infrastructure Carve-Out** (new in v1.1.0) — Actively exercised. The inspector and docs demo live under `wasm-apps/` and `docs/`, are not part of the library's public API, and their purpose is to exercise the Nix module. This is exactly the scenario Principle V was amended to cover.

**Quality Gates**:
- `just ci` continues to pass on the native path (unchanged recipe behavior for existing checks).
- New gates: `nix build .#checks.<sys>.wasm-tx-inspector`, `.#checks.<sys>.wasm-tx-inspector-tests`, `.#checks.<sys>.docs-site`, plus `.#lint` still runs over all Haskell sources (including the inspector).
- Demo subtree tests run in CI via `wasmtime` against fixtures.
- No mocks for node communication: unchanged.

**Gate verdict**: PASS. No constitution violations; no Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/033-wasm-ledger-inspector/
├── plan.md              # This file
├── research.md          # Phase 0 output — toolchain + override set decisions
├── data-model.md        # Phase 1 output — Structural tx JSON schema
├── quickstart.md        # Phase 1 output — downstream consumer how-to
├── contracts/           # Phase 1 output — CLI contract + Nix module API contract
│   ├── cli.md
│   └── nix-api.md
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit.specify)
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
# existing library and test layout — UNTOUCHED
lib/                                        # cardano-node-clients public library (N2C, chain-follower)
e2e-test/                                   # devnet-driven end-to-end tests
devnet/                                     # devnet helpers
cardano-node-clients.cabal                  # existing cabal metadata

# new: reusable Nix module for WASM cross-compilation of cardano-ledger subsets
nix/
└── wasm/
    ├── default.nix                         # flake entry, re-exports the module
    ├── project.nix                         # haskell.nix cabalProject' for wasm32 target
    ├── overrides.nix                       # haskellWasmOverlay — fork pins as an overlay
    ├── cabal-project-fragment.nix          # the `if arch(wasm32)` stanza as reusable cabal.project text
    ├── truncated-index.nix                 # two-phase FOD helpers for deterministic bootstrap
    ├── bootstrap-cabal.nix                 # bootstrap cabal store from truncated index
    ├── mkCardanoLedgerWasm.nix             # public builder: { pkgs, packages } -> derivation
    └── forks.json                          # vendored fork pins (source, rev, sha256)

# new: demo Haskell executable (Principle V carve-out)
wasm-apps/
└── tx-inspector/
    ├── tx-inspector.cabal
    ├── app/
    │   └── Main.hs                         # WASI reactor: stdin (hex) -> stdout (JSON)
    └── lib/
        └── Conway/
            ├── Inspector.hs                # core decode: TxBody -> StructuralTxJSON
            └── JSON.hs                     # aeson rendering of StructuralTxJSON

# new: fixtures captured from MPFS E2E for golden-JSON tests
test/
└── fixtures/
    └── conway/
        ├── boot.hex
        ├── boot.expected.json
        ├── request-insert.hex
        ├── request-insert.expected.json
        ├── update.hex
        └── update.expected.json

# new: MkDocs live demo (Principle V carve-out)
docs/
├── mkdocs.yml
├── index.md
├── module.md                               # how to consume the Nix module downstream
├── inspector/
│   ├── index.md                            # page embedding the inspector
│   ├── inspector.js                        # loads WASM + @bjorn3/browser_wasi_shim
│   └── assets/
│       └── inspector.wasm                  # populated at build time from flake package
└── stylesheets/
    └── extra.css

# flake + CI + justfile additions
flake.nix                                   # packages.wasm-tx-inspector, packages.docs-site, apps.*, checks.*
justfile                                    # build-wasm, build-docs, serve-docs, deploy-docs, ci additions
.github/workflows/
├── haskell-wasm.yml                        # build + wasmtime tests on every push
└── deploy-docs.yml                         # GitHub Pages on main
```

**Structure Decision**: Single repository, flat top-level tree. Existing library directories (`lib/`, `e2e-test/`, `devnet/`) stay as they are. Three new top-level directories (`nix/wasm/`, `wasm-apps/`, `docs/`) carve the feature's surface area clearly so downstream consumers of the library cannot accidentally pull demo code into their builds, and so the Nix module's scope stays focused on its one job. `test/fixtures/` sits under the repository root rather than inside `wasm-apps/tx-inspector/` so the fixtures are visible to any future consumer that wants to test another WASM app against the same ledger closure.

## Phase Breakdown

The plan splits into three independently shippable slices, one per user story priority, followed by cross-cutting CI + documentation polish.

### Slice A — P1: Nix module + trivial WASM build

**Goal**: a downstream flake can `inputs.cardano-node-clients.lib.wasm.mkCardanoLedgerWasm { packages = [...]; }` and get a WASM artifact.

- Author `nix/wasm/` scaffolding: `project.nix`, `overrides.nix`, `cabal-project-fragment.nix`, `forks.json`.
- Populate `forks.json` with the fork revs from IntersectMBO `cardano-api` master's `if arch(wasm32)` stanza (plutus, hs-memory, cborg, foundation, network, double-conversion, criterion, lmdb-mock); record nix32 SHA256 per the `/nix` skill.
- Implement `mkCardanoLedgerWasm` as a thin wrapper over `cabalProject'` that applies the overlay, injects the cabal.project fragment, and returns `hsPkgs.<pkg>.components.library` or the chosen executable closure.
- Implement the two-phase FOD pattern (`truncated-index.nix` + `bootstrap-cabal.nix`) per the `haskell-wasm` skill. Verify determinism: two independent builds of a trivial target produce byte-identical `.wasm`.
- Smoke-test target: a minimal Haskell "hello world" library depending on `cardano-ledger-binary` only; confirm it cross-compiles.
- Land as its own commit set on the branch; no behavioral change to existing flake outputs.

**Exit criteria**: `nix build .#checks.<sys>.wasm-smoke` green; deterministic output; no change to existing flake outputs.

### Slice B — P2: Tx inspector app + fixtures + wasmtime tests

**Goal**: `nix build .#wasm-tx-inspector` produces a `.wasm` that decodes Conway tx hex to structural JSON, tested against fixtures.

- Create `wasm-apps/tx-inspector/` cabal package. Public-sublibrary split (`lib/` for `Conway.Inspector` + `Conway.JSON`, `app/Main.hs` for the WASI reactor entry point).
- Implement `Conway.Inspector`: decode `cardano-ledger-conway`'s `Tx ConwayEra` from `ByteString`; project to a `StructuralTxJSON` record (see `data-model.md`).
- Implement `Conway.JSON`: `aeson` instances matching the data model; stable field ordering for golden comparisons.
- Capture fixtures from `cardano-mpfs-offchain` E2E (boot, request-insert, update): copy hex bytes into `test/fixtures/conway/*.hex`; generate `*.expected.json` by running the inspector native, spot-check against ledger structure, commit.
- Test harness: `nix/wasm/wasm-tx-inspector-tests.nix` wraps a shell script that loops over fixtures, invokes `wasmtime <artifact> < hex-file`, diffs stdout against `expected.json`.
- Wire as `packages.<sys>.wasm-tx-inspector` + `checks.<sys>.wasm-tx-inspector` + `checks.<sys>.wasm-tx-inspector-tests` in the flake.
- Error handling: distinguish era-mismatch, malformed CBOR, and structural decode errors; emit single-line message to stderr, exit non-zero, no partial JSON on stdout (FR-011).

**Exit criteria**: wasmtime test suite green over all fixtures; determinism check unchanged; FR-006..FR-011 acceptance scenarios pass.

### Slice C — P3: MkDocs live demo + GitHub Pages

**Goal**: a deployed docs URL where a reviewer pastes hex and sees JSON, with the inspector binary sourced from the flake package.

- Add `docs/` scaffold with mkdocs-material config via `paolino/dev-assets/mkdocs`. Pages: `index.md` (project overview), `module.md` (how to consume the Nix module, with a minimal downstream `flake.nix` example pulled from `quickstart.md`), `inspector/index.md` (the live demo).
- Implement `inspector/inspector.js` loading the `.wasm` via `@bjorn3/browser_wasi_shim@0.4.2`: feed stdin via `new OpenFile(new File(hexBytes))`, capture stdout via `ConsoleStdout.lineBuffered`, render JSON into a `<pre>`.
- Inspector `.wasm` pulled from the flake package at site build time — `packages.<sys>.docs-site` depends on `packages.<sys>.wasm-tx-inspector` and copies the artifact into `docs/inspector/assets/inspector.wasm` before `mkdocs build`.
- Browser capability fallback: detect missing WASM / `SharedArrayBuffer` support and show a readable explanation (edge case from spec).
- GitHub Pages deploy workflow: on `main`, builds `packages.<sys>.docs-site` and publishes; build failure fails the deploy (FR-015).
- Justfile recipes: `build-docs`, `serve-docs`, `deploy-docs` per the `workflow` skill.

**Exit criteria**: deployed docs URL passes SC-003 (paste → decoded JSON in ≤30 s); local `nix develop -c just serve-docs` reproduces the deployed page; deploy is atomic with inspector build.

### Cross-cutting — CI, lint, observability, PR polish

- `.github/workflows/haskell-wasm.yml`: sets up `nix`, builds `.#checks.<sys>.{wasm-smoke,wasm-tx-inspector,wasm-tx-inspector-tests,docs-site,lint}` via the nix-first CI pattern from the `workflow` skill.
- `.github/workflows/deploy-docs.yml`: main-only, depends on the build-gate job succeeding.
- `just ci` recipe extended to run the same checks locally.
- Lint: fourmolu + hlint applied to `wasm-apps/tx-inspector/` sources; `cabal-fmt` on its `.cabal` file.
- PR description kept up to date after every push per workflow rule; final pre-merge pass runs the full local `just ci`.

## Risks & Mitigations

- **Plutus 32-bit safety PR (IntersectMBO/plutus#7362) is still open upstream.** The cabal-wasm override set includes a plutus fork; we pin the same fork IntersectMBO uses in their green `cardano-wasm` build. Mitigation: explicit rev pin + SHA256 in `forks.json`; if upstream moves, we update the pin in one file.
- **Fork pins tracked from IntersectMBO revs may rebase.** First iteration references IntersectMBO forks; if we observe instability, Slice A gets a follow-up task to re-fork under `lambdasistemi` and update `forks.json`. Out of scope for this feature; tracked in the issue's follow-up list.
- **FOD non-determinism from terminal/log content in the repo.** The `/nix` skill warns that any file containing a matching 32-char store-path hash breaks fixed-output derivations. Before committing fixtures or screenshots, grep for `nix/store` and sanitize. We never commit logs from `nix develop`.
- **Conway tx schema evolution.** If `cardano-ledger-conway` bumps its tx body shape, fixtures may drift. Mitigation: bump the fork/CHaP pin in lockstep with a fixture refresh; the wasmtime tests fail loudly if expected JSON diverges.
- **Browser capability edge cases.** Some browsers ship WASM disabled or without `SharedArrayBuffer`. Mitigation: the demo detects and shows a fallback message, and CI tests cover the `wasmtime` path (which approximates node/server semantics but not every browser).
- **Docs deploy shipping stale artifacts if build ordering is wrong.** Mitigation: the flake makes `packages.<sys>.docs-site` depend on `packages.<sys>.wasm-tx-inspector`; the deploy workflow builds the site package, not the `mkdocs build` command directly.

## Open Follow-Ups (out of scope for this feature)

- Re-fork the override-set packages under `lambdasistemi` organization and update `forks.json` to point there — file as a separate issue in this repo after Slice A lands.
- MPFS client adoption of the module for the `Client.Verify` proof-binding work — file as a new issue in `cardano-mpfs-offchain` referencing `lambdasistemi/cardano-node-clients#68`.
- NPM package skeleton for browser consumers — tracked upstream in `cardano-mpfs-offchain#221`, not owned here.
- Signing / submission / tx construction from WASM — deferred per spec Assumptions.

## Complexity Tracking

No Constitution Check violations; no Complexity Tracking entries required.
