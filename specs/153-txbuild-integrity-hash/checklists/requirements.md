# Specification Quality Checklist: TxBuild self-validates against ledger Phase-1

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-15
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Constitutional alignment: regression test runs against a real
  ledger (cardano-ledger-api `applyTx`), not a mock — consistent
  with project Principle II "Devnet E2E Testing" / no-mocks rule.
- The spec deliberately references some ledger-side concepts
  (CBOR keys `0b` / `5`, Plutus language versions, witness-set
  datums map) because the bug is defined by them; this is not
  implementation leakage — it is the contract the produced tx
  body must satisfy with the ledger.
- One named ledger function appears (`applyTx` from
  `cardano-ledger-api`); kept because it pins down what
  "Phase-1 validation" means for the regression test and is
  unambiguous.
