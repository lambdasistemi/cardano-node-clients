# Specification Quality Checklist: Mainnet TxBuild Golden Vectors

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-04-12
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No `[NEEDS CLARIFICATION]` markers remain
- [x] Requirements are testable and bounded
- [x] Success criteria are measurable
- [x] The specification is ready for implementation

## Notes

- The issue originally phased reward-withdrawal vectors behind `#40`, but `#40` is already closed in the current repository state.
- The original `17a8e607...` Indigo stability vector was removed after verifying it is pre-Conway (`2024-04-22 13:12:14 UTC`).
- The implemented suite now runs both `draft` and `build` over the 11 committed Conway-era vectors, using offline input-value fixtures plus replayed original `ExUnits`.
