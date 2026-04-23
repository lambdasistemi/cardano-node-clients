---

description: "Task list for 033-wasm-ledger-inspector"
---

# Tasks: WASM Conway Tx Inspector + Vendored Cardano-Ledger WASM Nix Module + MkDocs Live Demo

**Input**: Design documents from `/specs/033-wasm-ledger-inspector/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, contracts/nix-api.md, quickstart.md

**Tests**: Included as explicit tasks because the feature depends on golden-JSON fixtures and deterministic builds — correctness is not self-evident from code alone.

**Organization**: Tasks grouped by user story so each story can ship independently. Setup and Foundational phases come first; Polish is the last phase. Owning documents are referenced by path rather than duplicated (spec.md, research.md, data-model.md, contracts/cli.md, contracts/nix-api.md).

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the directory scaffolding and branch hygiene before any real work begins.

- [ ] T001 Create top-level directories `nix/wasm/`, `wasm-apps/tx-inspector/`, `test/fixtures/conway/`, `docs/`, `.github/workflows/` in the worktree `/code/cardano-node-clients-wasm-inspector` per the Project Structure in `specs/033-wasm-ledger-inspector/plan.md`
- [ ] T002 [P] Add `.gitignore` entries for `result`, `result-*`, `docs/site/`, `docs/inspector/assets/inspector.wasm` at repo root
- [ ] T003 [P] Add a top-level `README.md` section linking to `specs/033-wasm-ledger-inspector/quickstart.md` so downstream consumers have a starting point

**Checkpoint**: Empty scaffolding committed; branch ready for feature work.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The vendored override set and two-phase FOD plumbing are the foundation every slice below depends on. Nothing in User Stories 1/2/3 can ship without these.

**⚠️ CRITICAL**: No user story work begins until Phase 2 completes.

- [ ] T004 Create `nix/wasm/forks.json` listing every vendored source-repository-package pin (owner, repo, rev, sha256, subdir?) — use the list of fork origins enumerated in `specs/033-wasm-ledger-inspector/research.md` Decision 3 as the source of truth; compute nix32 hashes per the `/nix` skill
- [ ] T005 Create `nix/wasm/cabal-project-fragment.nix` emitting the `if arch(wasm32)` cabal.project text — mirror the package flags and allow-newer list in `specs/033-wasm-ledger-inspector/research.md` Decision 3
- [ ] T006 Create `nix/wasm/overrides.nix` implementing the `haskellWasmOverlay` (haskell.nix overlay) sourcing fork pins from `nix/wasm/forks.json`
- [ ] T007 Create `nix/wasm/truncated-index.nix` implementing the deterministic Hackage index truncation FOD per `specs/033-wasm-ledger-inspector/research.md` Decision 4 and the `haskell-wasm` skill's "Two-phase FOD" section
- [ ] T008 Create `nix/wasm/bootstrap-cabal.nix` building the bootstrapped cabal store from the truncated index (FOD phase 1)
- [ ] T009 Create `nix/wasm/project.nix` wrapping `haskell.nix cabalProject'` with the overlay + the cabal-project fragment + the bootstrapped cabal store, producing a `wasm32-wasi` project
- [ ] T010 Create `nix/wasm/mkCardanoLedgerWasm.nix` implementing the public `mkCardanoLedgerWasm` builder matching the signature in `specs/033-wasm-ledger-inspector/contracts/nix-api.md`
- [ ] T011 Create `nix/wasm/default.nix` re-exporting `cabalWasmProjectFragment`, `haskellWasmOverlay`, `mkCardanoLedgerWasm`, `forks` — the exact surface pinned in `specs/033-wasm-ledger-inspector/contracts/nix-api.md`
- [ ] T012 Wire `outputs.lib.wasm = import ./nix/wasm { inherit pkgs; }` into `flake.nix` without touching existing N2C flake outputs (FR-016)
- [ ] T013 Add `ghc-wasm-meta` as a flake input pinned to `gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org#all_9_12` per `specs/033-wasm-ledger-inspector/research.md` Decision 1

**Checkpoint**: `nix eval .#lib.wasm` succeeds and exposes the four documented attributes; existing flake outputs unchanged.

---

## Phase 3: User Story 1 — Downstream flake cross-compiles a ledger subset to WASM (Priority: P1) 🎯 MVP

**Goal**: a downstream flake can call `lib.wasm.mkCardanoLedgerWasm { packages = [...]; }` and get a reproducible `.wasm`.

**Independent Test**: `nix build .#checks.<sys>.wasm-smoke` green; two independent builds byte-identical; no changes to existing flake outputs.

### Tests for User Story 1

- [ ] T014 [P] [US1] Add `nix/wasm/smoke/flake.nix` + `nix/wasm/smoke/default.nix` — a self-contained trivial "hello from ledger" Haskell library consuming `cardano-ledger-binary` via `lib.wasm.mkCardanoLedgerWasm`, used as the smoke test
- [ ] T015 [US1] Add `nix/wasm/smoke/determinism-check.sh` — builds the smoke target twice into distinct store paths, diffs their `.wasm` bytes, fails on any difference (SC-002)

### Implementation for User Story 1

- [ ] T016 [US1] Materialize the override set against a concrete ledger closure: run `nix build nix/wasm/smoke#default` and resolve any build errors by tightening `forks.json` / `cabal-project-fragment.nix` (iterative until green) — guided by the blockers catalogued in `specs/033-wasm-ledger-inspector/research.md` Decision 3
- [ ] T017 [US1] Expose `packages.<sys>.wasm-smoke` = the smoke target in `flake.nix` so CI can `nix build` it directly
- [ ] T018 [US1] Expose `checks.<sys>.wasm-smoke` and `checks.<sys>.wasm-smoke-determinism` wrapping T014/T015 so they run under `nix flake check`
- [ ] T019 [US1] Add `quickstart.md` reference `nix/wasm/README.md` summarizing how to use `mkCardanoLedgerWasm` — keep it ≤30 lines, link to `specs/033-wasm-ledger-inspector/quickstart.md` for the full walkthrough

**Checkpoint**: US1 shippable. A downstream project can import `lib.wasm` and build a ledger subset to WASM deterministically. MVP demonstrably delivers the core infra.

---

## Phase 4: User Story 2 — Reviewer decodes a Conway tx body without installing anything (Priority: P2)

**Goal**: `nix build .#wasm-tx-inspector` produces a `.wasm` that maps Conway tx hex → StructuralTxJSON; fixtures pass under `wasmtime`.

**Independent Test**: the three MPFS E2E fixture hexes fed through the inspector under `wasmtime` emit JSON byte-identical to `test/fixtures/conway/*.expected.json`.

### Tests for User Story 2

- [ ] T020 [P] [US2] Capture fixture hex files from `cardano-mpfs-offchain` E2E runs and write `test/fixtures/conway/{boot,request-insert,update}.hex` per `specs/033-wasm-ledger-inspector/research.md` Decision 8
- [ ] T021 [US2] Generate `test/fixtures/conway/{boot,request-insert,update}.expected.json` by running the native build of the inspector (from T024) against each hex, then hand-review against the ledger's own structure before committing (golden freeze)
- [ ] T022 [P] [US2] Create `nix/wasm/wasm-tx-inspector-tests.nix` — wraps a shell script that loops over fixtures, invokes `wasmtime <artifact> < hex`, diffs stdout against `*.expected.json`, fails on any diff
- [ ] T023 [P] [US2] Add negative-case tests: malformed hex, truncated CBOR, non-Conway tx — each must exit non-zero with one of the error categories in `specs/033-wasm-ledger-inspector/contracts/cli.md`

### Implementation for User Story 2

- [ ] T024 [US2] Create `wasm-apps/tx-inspector/tx-inspector.cabal` declaring a public library `tx-inspector` + an executable `wasm-tx-inspector` — depend on `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`, `aeson`, `bytestring`, `base16-bytestring`
- [ ] T025 [P] [US2] Implement the `Data` AST renderer in `wasm-apps/tx-inspector/lib/Conway/Inspector/PlutusData.hs` matching the `PlutusDataView` shape in `specs/033-wasm-ledger-inspector/data-model.md`
- [ ] T026 [P] [US2] Implement `Value` + `MintMap` rendering in `wasm-apps/tx-inspector/lib/Conway/Inspector/Value.hs` matching `specs/033-wasm-ledger-inspector/data-model.md`
- [ ] T027 [US2] Implement `Conway.Inspector` in `wasm-apps/tx-inspector/lib/Conway/Inspector.hs` — decode `Tx ConwayEra` and project to the `StructuralTxJSON` record declared in `specs/033-wasm-ledger-inspector/data-model.md` (uses T025/T026)
- [ ] T028 [US2] Implement aeson instances in `wasm-apps/tx-inspector/lib/Conway/Inspector/JSON.hs` — stable field ordering per the top-level key sequence in `specs/033-wasm-ledger-inspector/data-model.md`
- [ ] T029 [US2] Implement the CLI entry point in `wasm-apps/tx-inspector/app/Main.hs` — buffer full JSON before writing to stdout, error categories per `specs/033-wasm-ledger-inspector/contracts/cli.md`, no partial output on failure (FR-011)
- [ ] T030 [US2] Wire `packages.<sys>.wasm-tx-inspector` in `flake.nix` via `lib.wasm.mkCardanoLedgerWasm` with the inspector's cabal package included via `extraCabalProject`
- [ ] T031 [US2] Wire `checks.<sys>.wasm-tx-inspector` (build) and `checks.<sys>.wasm-tx-inspector-tests` (fixtures under wasmtime, from T022) in `flake.nix`
- [ ] T032 [US2] Add fourmolu + hlint + cabal-fmt coverage for `wasm-apps/tx-inspector/` by extending the repo's existing `checks.<sys>.lint`

**Checkpoint**: US2 shippable. Inspector decodes Conway tx hex to JSON under wasmtime, three fixtures pass. MPFS client has a concrete consumer to validate against, independent of US3.

---

## Phase 5: User Story 3 — Live demo on the project documentation (Priority: P3)

**Goal**: the published docs site hosts a page that decodes pasted tx hex in-browser using the same `.wasm` artifact.

**Independent Test**: a reviewer navigates to the deployed docs URL, pastes one of the fixture hexes, and sees decoded JSON in under 30 seconds (SC-003).

### Tests for User Story 3

- [ ] T033 [P] [US3] Add a headless-browser smoke test in `.github/workflows/deploy-docs.yml` post-deploy step that fetches the inspector page and asserts the page element for "paste tx hex" is present
- [ ] T034 [P] [US3] Add `nix/wasm/docs-site-check.nix` — verifies `docs/inspector/assets/inspector.wasm` in the built site is byte-identical to `packages.<sys>.wasm-tx-inspector`'s artifact (FR-013)

### Implementation for User Story 3

- [ ] T035 [US3] Add `paolino/dev-assets/mkdocs` as a flake input; expose it in `flake.nix`'s `perSystem.devShells.default` via `inputsFrom` per the `/workflow` skill
- [ ] T036 [P] [US3] Author `docs/mkdocs.yml` — mkdocs-material config, site name, navigation (Home, Module, Inspector), theme, plugins (mermaid2)
- [ ] T037 [P] [US3] Author `docs/index.md` — overview of the feature with links to the Nix module and the live inspector; cross-link `specs/033-wasm-ledger-inspector/quickstart.md`
- [ ] T038 [P] [US3] Author `docs/module.md` — module consumption guide; prose version of `specs/033-wasm-ledger-inspector/quickstart.md`
- [ ] T039 [P] [US3] Author `docs/inspector/index.md` — page embedding the inspector: textarea for hex input, "Decode" button, `<pre>` for JSON output, error banner
- [ ] T040 [US3] Author `docs/inspector/inspector.js` — loads `@bjorn3/browser_wasi_shim@0.4.2`, feeds stdin via `new OpenFile(new File(hexBytes))`, captures stdout via `ConsoleStdout.lineBuffered`, renders JSON; detects missing WASM / `SharedArrayBuffer` and shows the edge-case fallback message from the spec
- [ ] T041 [US3] Add `packages.<sys>.docs-site` in `flake.nix` that depends on `packages.<sys>.wasm-tx-inspector`, copies the `.wasm` into `docs/inspector/assets/inspector.wasm`, then runs `mkdocs build` (FR-013)
- [ ] T042 [US3] Add `apps.<sys>.serve-docs` and `apps.<sys>.deploy-docs` in `flake.nix` per the `/workflow` skill standard docs recipes
- [ ] T043 [US3] Add justfile recipes `build-docs`, `serve-docs`, `deploy-docs` calling the corresponding flake apps
- [ ] T044 [US3] Add `.github/workflows/deploy-docs.yml` — on `main` only, depends on the build-gate workflow (from the cross-cutting phase), builds `packages.<sys>.docs-site`, publishes to GitHub Pages, fails atomically if the inspector build fails (FR-015, SC-005)

**Checkpoint**: US3 shippable. Docs site deployed with a working inspector; no stale-artifact path; build-gate ↔ deploy linkage atomic.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: CI wiring, PR description polish, and final validation that existing functionality is intact.

- [ ] T045 [P] Author `.github/workflows/haskell-wasm.yml` — uses `paolino/dev-assets/setup-nix@v0.0.1`, builds `.#checks.<sys>.{wasm-smoke, wasm-smoke-determinism, wasm-tx-inspector, wasm-tx-inspector-tests, docs-site, lint}`, on every push
- [ ] T046 Extend the repo's existing `just ci` recipe to run the new checks so `nix develop -c just ci` mirrors GitHub CI (per `/workflow` skill "Pre-Push CI Check")
- [ ] T047 [P] Verify the existing N2C library, devnet, chain-follower test suites still pass: `nix develop -c just ci` on the native path (SC-006, SC-007)
- [ ] T048 [P] Update `CHANGELOG.md` with a feat entry pointing to issue #68 and PR #69
- [ ] T049 Update PR #69 body with final status, links to `docs-site` artifact URL, and acceptance-scenario walkthrough (per `/workflow` skill "PR descriptions are living documents")
- [ ] T050 Run `specs/033-wasm-ledger-inspector/quickstart.md` end-to-end on a clean clone: build the smoke target, build the inspector, run a fixture under wasmtime, run the docs site locally; record any friction as a follow-up issue
- [ ] T051 File follow-up issues for (a) re-forking override-set packages under `lambdasistemi`, (b) MPFS client adoption of the module — both listed in plan.md "Open Follow-Ups"; link them from the closing comment on #68

**Checkpoint**: feature ready for merge via merge-guard per `/workflow`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 Setup**: no dependencies.
- **Phase 2 Foundational**: depends on Phase 1; BLOCKS all user stories. This is where the override set and FOD plumbing land.
- **Phase 3 US1**: depends on Phase 2.
- **Phase 4 US2**: depends on Phase 2; independent of US1's smoke target (uses `mkCardanoLedgerWasm` too but with a different package set).
- **Phase 5 US3**: depends on US2 (it consumes `packages.<sys>.wasm-tx-inspector`).
- **Phase 6 Polish**: depends on all user stories targeted for this release; T045 can be authored in parallel with US work but only goes green after Phase 2 lands.

### User Story Dependencies

- **US1 (P1)**: pure foundation consumer; no story dependencies.
- **US2 (P2)**: independent of US1 (both use `mkCardanoLedgerWasm`; US2 does not depend on US1's smoke target).
- **US3 (P3)**: depends on US2 (the demo hosts the inspector binary). Do not start US3 until US2's `packages.<sys>.wasm-tx-inspector` exists.

### Within Each Story

- Fixtures (T020/T021) must land before US2 tests can be green.
- Library modules (T025/T026) before `Conway.Inspector` (T027), which is before `Conway.Inspector.JSON` (T028), which is before the CLI entry point (T029).
- `packages.<sys>.wasm-tx-inspector` (T030) before `checks.<sys>.wasm-tx-inspector-tests` (T031).

### Parallel Opportunities

- Phase 1: T002, T003 in parallel with T001 after T001's directories exist.
- Phase 2: T005, T006, T007 touch different files and can run in parallel after T004.
- US2: T020 (fixture capture), T022 (test harness), T023 (negative cases) touch different files; T025 (PlutusData), T026 (Value) are independent modules that can be written side by side.
- US3: T036, T037, T038, T039 are four distinct Markdown / YAML files with no internal dependencies.
- Polish: T045, T047, T048 all touch different files and can run in parallel.

---

## Parallel Example: User Story 2

```bash
# Launch library modules together:
Task: "Implement the Data AST renderer in wasm-apps/tx-inspector/lib/Conway/Inspector/PlutusData.hs"
Task: "Implement Value + MintMap rendering in wasm-apps/tx-inspector/lib/Conway/Inspector/Value.hs"

# Launch test artifacts in parallel with library work:
Task: "Capture fixture hex files from cardano-mpfs-offchain E2E runs"
Task: "Create nix/wasm/wasm-tx-inspector-tests.nix harness"
Task: "Add negative-case tests for malformed/truncated/non-Conway input"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US1.
2. **STOP and VALIDATE**: `nix build .#checks.<sys>.wasm-smoke`, then the determinism check.
3. If green and independent downstream can consume the module — the MVP is shipped. Everything else is additive.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 → ship (MVP): downstream has the Nix module.
3. US2 → ship: repo has a concrete consumer, MPFS proof-binding work unblocks.
4. US3 → ship: docs live, demo visible to external reviewers.
5. Polish → merge-guard.

### Parallel Team Strategy

With more than one developer:

1. Phase 1 + Phase 2 done by one person (Foundational is serialized across files).
2. After Phase 2 checkpoint:
   - Dev A: US1 (smoke + determinism).
   - Dev B: US2 fixtures (T020/T021) + library (T024..T029).
   - Dev C starts US3 Markdown/JS authoring (T036..T040) — can begin before US2 lands, blocked on T030/T031 only for the final wiring.
3. Polish integrates all three.

---

## Notes

- [P] marks tasks that touch different files with no unmet dependencies; they may run in parallel.
- [Story] labels map each task to its owning user story for traceability.
- Fork pin list is in `specs/033-wasm-ledger-inspector/research.md` Decision 3 — tasks reference it, do not duplicate.
- JSON schema is in `specs/033-wasm-ledger-inspector/data-model.md` — tasks reference it, do not duplicate.
- Commit after each task or small cohesive group (per `/workflow` skill "Small Focused Commits").
- Use StGit for any retroactive patch placement per `/workflow` skill.
- After every push, update PR #69 body (per `/workflow` skill "PR descriptions are living documents").
- Before every push, run `nix develop -c just ci` locally (per `/workflow` skill "Pre-Push CI Check"); no CI round-trip debugging.
