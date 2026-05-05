# Specification Quality Checklist: TxBuild Conway collateral fields

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-05
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

- The spec is technical-by-domain (Conway CBOR keys, ledger types) but those are surface-level vocabulary — none of the FRs prescribe a Haskell module layout, lens names, or call sites. The plan phase will translate these into concrete code touchpoints (`TxInstr`, `TxState`, `assembleTxWith`, `Balance.hs`).
- `setCollateralReturn :: Addr -> TxBuild q e ()` is mentioned because it's a contract surface, not an implementation detail — it's the only caller-visible API addition and must be agreed before implementation.
