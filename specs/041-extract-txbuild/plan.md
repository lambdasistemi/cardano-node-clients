# Implementation Plan: Extract TxBuild

**Branch**: `041-extract-txbuild` | **Date**: 2026-05-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/041-extract-txbuild/spec.md`

## Status

**Completed**: Created the public `tx-build` sublibrary, moved
`Ledger`, `Balance`, and `TxBuild` implementation modules into
`lib-tx-build`, added main-library re-exports for the existing module
names, added a focused `tx-build-tests` suite, added the dependency
boundary check, and documented the split in README and docs. All tasks
in `tasks.md` are complete.

**Current**: Ready for external PR review; final gate run passed.

**Blockers**: None. The unrelated staged `test/fixtures/pparams.json`
remains outside this feature work.

**Verification**:

- `scripts/check-tx-build-boundary.sh`: passed.
- Negative boundary smoke with temporary `network` dependency: failed as
  expected, then passed after removal.
- `nix develop --quiet -c cabal build lib:tx-build -O0`: passed.
- `nix develop --quiet -c cabal test cardano-node-clients:tx-build-tests -O0 --test-show-details=direct`: passed, 34 examples, 0 failures.
- `nix develop --quiet -c cabal build cardano-node-clients -O0`: passed.
- `nix develop --quiet -c cabal test cardano-node-clients:unit-tests -O0 --test-options='--match /TxBuild/' --test-show-details=direct`: passed, 36 examples, 0 failures.
- `nix develop --quiet -c cabal test cardano-node-clients:unit-tests -O0 --test-options='--match /balanceTx/' --test-show-details=direct`: passed, 2 examples, 0 failures.
- `nix develop --quiet -c cabal build cardano-node-clients:cardano-tx-generator -O0`: passed.
- `nix develop --quiet -c just format`: passed.
- `nix develop --quiet -c just hlint`: passed, no hints.
- `nix develop --quiet -c just unit`: passed, 217 examples, 0 failures.
- `nix develop --quiet -c just build`: passed.
- `nix develop --quiet -c just ci`: passed; build, E2E, unit,
  cabal-fmt, fourmolu, and hlint checks completed successfully.

## Summary

Extract the TxBuild and Balance implementation into a small public
library component that has no node networking, chain follower, indexer,
daemon, socket, devnet, or RocksDB dependencies. Keep
cardano-node-clients source-compatible by re-exporting the old module
names from the main library and making existing tx-generator and tests
consume the extracted component.

## Technical Context

**Language/Version**: Haskell, GHC2021  
**Primary Dependencies**: Cabal, Nix, cardano-ledger packages,
cardano-binary, cardano-slotting, cardano-strict-containers,
microlens, operational, plutus-core, plutus-tx  
**Storage**: N/A for extracted transaction-building component  
**Testing**: `just unit`, focused Cabal tests, golden vectors, boundary
dependency check  
**Target Platform**: Haskell library consumers on the current
cardano-node 10.7 dependency line  
**Project Type**: Multi-component Haskell library  
**Performance Goals**: Preserve current TxBuild and Balance runtime
behavior; no new network or indexer initialization for transaction-only
consumers  
**Constraints**: Preserve current public module compatibility; do not
move N2C, devnet, tx-generator daemon, UTxO indexer, or RocksDB into the
extracted component  
**Scale/Scope**: One extracted transaction-building component, main
library compatibility re-exports, focused tests and docs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Channel-Driven N2C Clients**: Pass. The feature does not change
  N2C client architecture; it moves transaction construction away from
  the N2C component boundary.
- **II. Devnet E2E Testing**: Pass. Existing devnet E2E coverage remains
  in the main package; extracted transaction-building coverage is unit
  and golden-vector focused.
- **III. Minimal Dependencies**: Pass. This feature directly improves
  the dependency boundary by isolating TxBuild from networking and
  indexer dependencies.
- **IV. Test Utilities Are First-Class**: Pass. Existing test utilities
  remain public; transaction-building tests become more directly
  reusable.

## Project Structure

### Documentation (this feature)

```text
specs/041-extract-txbuild/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── public-surface.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
cardano-node-clients.cabal
lib-tx-build/
└── Cardano/Node/Client/
    ├── Balance.hs
    ├── Ledger.hs
    └── TxBuild.hs
lib/
└── Cardano/Node/Client/
    ├── Evaluate.hs       # remains in main library
    └── ...
test/
└── Cardano/Node/Client/
    ├── BalanceSpec.hs
    ├── TxBuildSpec.hs
    └── TxBuildGoldenSpec.hs
docs/
└── modules/
    └── txbuild.md
```

**Structure Decision**: Use a public Cabal sublibrary in this repository
for the first extraction. This proves the boundary and lets downstreams
depend on only the transaction-building component while preserving the
current package and module names through main-library re-exports.

## Phase 0 Research Summary

See [research.md](./research.md).

Key decisions:

- Extract `TxBuild`, `Balance`, and the Conway transaction alias
  together.
- Keep `Evaluate` in the main library for now because it depends on the
  provider abstraction.
- Preserve old module names via main-library re-exported modules.
- Add a focused boundary check over the extracted component's
  dependencies.

## Phase 1 Design Summary

See [data-model.md](./data-model.md) and
[contracts/public-surface.md](./contracts/public-surface.md).

The extracted component owns transaction construction and balancing.
The main library owns live node communication, provider-backed
evaluation, submission, devnet, tx-generator daemon, and UTxO indexing.

## Post-Design Constitution Check

- **I. Channel-Driven N2C Clients**: Pass. N2C stays in the main
  library.
- **II. Devnet E2E Testing**: Pass. E2E remains unchanged and can still
  exercise compatibility imports.
- **III. Minimal Dependencies**: Pass. The extracted component has an
  explicit forbidden-dependency check.
- **IV. Test Utilities Are First-Class**: Pass. Test coverage is split
  by boundary without hiding existing public helpers.

## Complexity Tracking

No constitution violations.
