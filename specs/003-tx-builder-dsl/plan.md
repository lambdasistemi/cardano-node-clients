# Implementation Plan: Transaction Builder DSL

**Branch**: `003-tx-builder-dsl` | **Date**: 2026-04-10 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-tx-builder-dsl/spec.md`

## Summary

Add a Scalus-inspired transaction builder DSL to `cardano-node-clients`. The builder is an immutable step accumulator with typed combinators for script spends, minting, reference inputs, validity intervals, and inline datums. A single `build` function absorbs all mechanical boilerplate: redeemer index computation, script integrity hashing, ExUnits evaluation/patching, and fee balancing. The technical spec is at `/code/cardano-tx-sim-spec.md`.

## Technical Context

**Language/Version**: Haskell (GHC 9.6+, same as cardano-node-clients)
**Primary Dependencies**: cardano-ledger-api, cardano-ledger-conway, plutus-ledger-api, plutus-tx (ToData/FromData)
**Storage**: N/A
**Testing**: hspec, existing e2e devnet tests
**Target Platform**: Linux (same as cardano-node-clients)
**Project Type**: Library module within cardano-node-clients
**Constraints**: No cardano-api dependency. Must work with existing Provider and Balance modules.

## Constitution Check

No constitution file found. Proceeding with project conventions:
- Function records, not typeclasses
- Existential `ToData` for typed redeemers/datums
- cardano-ledger types directly, no cardano-api

## Project Structure

### Documentation (this feature)

```text
specs/003-tx-builder-dsl/
├── plan.md
├── research.md
├── data-model.md
├── tasks.md
└── checklists/
    └── requirements.md
```

### Source Code (repository root)

```text
lib/Cardano/Node/Client/
├── TxBuild.hs          # TxBuilder type, steps, combinators
├── TxBuild/
│   └── Build.hs        # build, complete, draft (assembly + evaluation)
├── Balance.hs          # Existing — no changes
├── Provider.hs         # Existing — no changes
└── ...

test/Cardano/Node/Client/
└── TxBuildSpec.hs      # Unit tests for builder combinators + assembly
```

**Structure Decision**: Single new module `TxBuild.hs` with a submodule for the assembly logic. Keeps the public API (combinators) separate from the internal machinery (index computation, integrity hash, evaluation patching).
