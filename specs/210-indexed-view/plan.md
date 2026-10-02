# Plan v1 — #210

## Ownership and sequence

The ticket owner owns this mandate, gates, PR metadata and acceptance.
The approved commit owner owns all production, tests, fault patches and CI
changes. The approved auditor reads commits/receipts from a separate detached
worktree and sends checkpoint verdicts only through the ticket owner.

| Slice | Contract | Owned production and proof surface |
|---|---|---|
| S1 | V1–V3; C4 library compatibility | Indexer read API, new view specs on both backends, view fault check and CI wiring, library docs |
| S2 | V4; C4 wire compatibility | Server request/response, socket specs and two fault checks with CI wiring, wire docs |

S1 must pass before S2. No S2 implementation without the epic's Q-001 answer.
No commit owner launches before acceptance of this intake. The epic owner
decides the per-slice merge/PR lifecycle (ticket question Q-001); the ticket
owner never merges. A planning push is not a SLICE-GREEN submission.

## Design decisions

- D1: use an additive batch read on `IndexerHandle` (F210-1), carrying an
  ordered nonempty query list and producing a materialized immutable view.
  Subsequent consumer traversal cannot reread storage. No storage handle,
  iterator or callback escapes the transaction lifetime.
- D2: retain the existing indexed-point source and typed asset unavailability.
  No independent point cache. Reuse #200's asset/provenance semantics within
  the view transaction; no composition of separate public IO reads.
- D3: preserve store/backends and ledger-free sublibrary dependencies. Prove
  transaction isolation on both in-memory and RocksDB; verify the actual
  pinned runner/snapshot lifetime before claiming it meets V1.
- D4: S2 binds a current view to P; it does not reconstruct historical state.
  Equality includes the block hash. The deadline bounds retries while behind
  P; any final response/refusal uses its own snapshot point. Readiness and
  disclosure samples cannot substitute for the storage point.
- D5: extend existing fault-check infrastructure for three new controls.
  Fault patches alter shipped read behavior in an isolated source copy;
  normal and faulted builds run the same model/assertion. The runner must
  execute exactly one intended example and classify setup separately.

## Team and checkpoints

Operator-selected roster, from the 2026-10-02 brief:

- Owner: `codex --dangerously-bypass-approvals-and-sandbox -C <worktree> -m gpt-6.1-sol -c model_reasoning_effort=high`.
- Auditor: `claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high`, separate detached worktree.
- Fresh panes, roots and briefs at every commit. No gate authors, draft tool,
  substitutions or gpt-6-luna. Only the ticket owner pushes.

One proposed final code commit per slice; no implementation commit plan may
reuse seats across commits. A need for additional commits requires a fresh
owner/auditor pair. Checkpoints cover the durable RED bundle, every acceptance
line GREEN, and pre-push. Owners continue working; all checkpoint approvals
are prerequisites for push. Auditor may add a mapped CI row, leaving settled
rows byte-identical. Scope/signature/gate contradictions go upward as Q files.

Before dispatch, record runnable gate hashes, exact base, fences, receipt
paths, baseline result and any resource allocation. No baseline, behavioral
RED, candidate GREEN or audit result has been executed/claimed at intake.

Before every push: fetch origin, require `origin/main` ancestor of HEAD;
otherwise merge main and re-gate, never rebase. After push, require green CI
on that exact head before SLICE-GREEN. Check inbox before every phase, push
and COMPLETE. Retain residuals in the PR body. No issue/PR comments.

Planning artifacts: each at most 6 KiB/100 lines; total at most 24 KiB/350
lines. Compiled child packet at most 12 KiB/180 lines excluding linked
skills/evidence. Record actual sizes; native token telemetry unavailable until
reported. Limits apply to prose, not implementation execution budgets.
