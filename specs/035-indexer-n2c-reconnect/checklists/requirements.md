# Specification Quality Checklist: utxo-indexer auto-reconnect on N2C peer close

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-04-29 (revised 2026-04-30)
**Feature**: [spec.md](../spec.md)
**Issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/97
**Bug regression test (already on main)**: https://github.com/lambdasistemi/cardano-node-clients/pull/100
**Prometheus follow-up**: https://github.com/lambdasistemi/cardano-node-clients/issues/101

## Content Quality

- [X] No implementation details (languages, frameworks, APIs)
- [X] Focused on user value and business needs
- [X] Written for non-technical stakeholders
- [X] All mandatory sections completed

## Requirement Completeness

- [X] No [NEEDS CLARIFICATION] markers remain
- [X] Requirements are testable and unambiguous
- [X] Success criteria are measurable
- [X] Success criteria are technology-agnostic (no implementation details)
- [X] All acceptance scenarios are defined
- [X] Edge cases are identified
- [X] Scope is clearly bounded
- [X] Dependencies and assumptions identified

## Feature Readiness

- [X] All functional requirements have clear acceptance criteria
- [X] User scenarios cover primary flows
- [X] Feature meets measurable outcomes defined in Success Criteria
- [X] No implementation details leak into specification

## Notes

- Spec is anchored on issue #97 + the reproducer landed in PR #100. The bug is real and reproducible (verified empirically) — no [NEEDS CLARIFICATION] on the premise.
- Single-peer reconnect is in scope; multi-peer failover is out-of-scope under Assumptions.
- Supervisor uses `Control.Retry`'s `capDelay (fullJitterBackoff _)` rather than hand-rolled backoff (research.md § D2). The library is already in the dep closure.
- Probe-then-connect: a separate LSQ tip probe (research.md § D6) sits in front of chain-sync. Default probe timeout = unbounded so chain replay is tolerated; operators set `--node-ready-timeout-ms` for a finite cap.
- Prometheus `blockReplayProgress` UX improvement deferred to https://github.com/lambdasistemi/cardano-node-clients/issues/101.
- Consumer-side degraded-response semantics during disconnect (FR-005/FR-006/US2) — chosen `not-ready` reply (additive `upstream` JSON object), documented in `contracts/control-wire.md`.
