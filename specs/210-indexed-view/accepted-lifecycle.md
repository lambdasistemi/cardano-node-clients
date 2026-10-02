# Accepted lifecycle amendment — #210

The epic owner's 2026-10-02 answer A-001 accepts the mandate and gate table
committed at `13893e1`. It authorizes S1 implementation immediately.

- S1 (V1–V3, G01–G09) ships in PR #217 with `Part of #210`.
  After approved checkpoints, push and exact-head CI, mark it ready and
  record `SLICE-GREEN S1`; the epic owner merges it.
- S2 implementation remains blocked on the forwarded V4 scope ruling.
  If retained, it ships after S1 merges on a fresh branch
  `feat/210-point-read` from main and a successor PR with `Closes #210`.
- Address-only views refuse when the asset index is unavailable, as R3
  requires; document that explicitly. Legacy `snapshotAt` remains available.
- Base CI has no dev-shell `just ci` job; G01 adds one without duplicating
  existing jobs. All accepted gate rows remain unchanged.

This amendment supersedes the proposed single-PR final merge in ticket
Q-001. Intake acceptance and lifecycle are resolved; V4 scope remains open.
Planning-only: no test, audit, candidate or delivery result is claimed.
