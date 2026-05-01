# Implementation Plan: Balance-Aware ExUnits

**Branch**: `039-exunits-after-balance` | **Date**: 2026-05-01 | **Spec**: `specs/039-exunits-after-balance/spec.md`
**Input**: Feature specification from `/specs/039-exunits-after-balance/spec.md`

## Status

**Completed**: Baseline CI gate passed on the branch before edits. Speckit
specification created from issue #112.  
**Current**: Implement regression tests and balance-aware ExUnits
convergence.  
**Blockers**: None.

## Summary

`build` and `evaluateAndBalance` currently patch redeemer ExUnits from an
evaluation that does not include later balancing mutations such as change
outputs and fee inputs. The fix is to make both workflows evaluate the
balanced transaction before deciding that redeemer ExUnits are final, and
to rebalance when that final evaluation changes ExUnits.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via repository Nix shell  
**Primary Dependencies**: `cardano-ledger-*`, `plutus-*`, existing
`Cardano.Node.Client.Balance` and transaction builder modules  
**Storage**: N/A  
**Testing**: Hspec unit tests, repository e2e suite  
**Target Platform**: Haskell library on Linux/Nix CI  
**Project Type**: Library  
**Performance Goals**: Maintain existing convergence behavior; add only
the evaluations needed to prove the balanced transaction's ExUnits.  
**Constraints**: Preserve public APIs; preserve deterministic error
reporting; keep existing margin semantics.  
**Scale/Scope**: `TxBuild.buildWith`, `TxBuild.build`, and
`Evaluate.evaluateAndBalance`.

## Constitution Check

- Channel-driven N2C clients: no changes to node communication APIs.
- Devnet E2E testing: existing e2e suite remains the integration gate.
- Minimal dependencies: no new dependencies planned.
- Test utilities first-class: regression coverage stays in the existing
  Hspec unit suite with deterministic evaluator functions.
- Quality gate: CI command is
  `nix build --quiet .#checks.x86_64-linux.build .#checks.x86_64-linux.e2e .#checks.x86_64-linux.lint`.

## Project Structure

### Documentation (this feature)

```text
specs/039-exunits-after-balance/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── tasks.md
```

### Source Code

```text
lib/Cardano/Node/Client/
├── Evaluate.hs
└── TxBuild.hs

test/Cardano/Node/Client/
└── TxBuildSpec.hs
```

**Structure Decision**: Keep the change in the existing transaction
assembly modules and existing TxBuild test module. No new library module
or public API is required.

## Implementation Notes

- Factor common redeemer patching/evaluation helpers only if it reduces
  duplication without changing exported APIs.
- For `buildWith`, convergence must include ExUnits stability in
  addition to the existing fee and `Peek` convergence checks.
- For `evaluateAndBalance`, a small local convergence loop is sufficient:
  evaluate, patch, balance, evaluate balanced, patch again, rebalance
  until redeemer ExUnits and fee are stable.
- Existing `boExUnitsMargin` applies at the point ExUnits are patched
  into redeemers.

## Complexity Tracking

No constitution violations.
