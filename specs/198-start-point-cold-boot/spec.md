# Spec: csStartPoint is cold-boot only (#198)

Docs and diagnostics only. No behaviour change.

## User stories

- **US1** — A consumer configuring `ChainSyncConfig` learns from this
  repository, not from a downstream consumer, that `csStartPoint` is
  consulted only on a cold boot (empty rollback log) and ignored once
  the store holds any retained resume point.
- **US2** — An operator hitting the warm-boot fail-closed error sees
  both routes that lead to it, with the recovery for each, instead of
  only the alarming one.

## Requirements

- **R1** — The Haddock on `csStartPoint` states when it is consulted:
  only when the follower has no usable stored resume point — (i) the
  UTxO store holds no rollback-log row (cold boot), or (ii) a history
  attachment is configured and the shared resume point is absent (the
  history store has no cursor). In every other case resume candidates
  come from the stores and the configured point is ignored.
- **R2** — The Haddock on `coldBootResumePoints` states the same rule
  from its side: it is consulted only in cases (i) and (ii) of R1.
- **R3** — The `WarmBoot` `intersectNotFound` error names both routes:
  - (a) the saved chain diverged from the node beyond the security
    parameter `k`;
  - (b) the store is younger than the rollback depth: it cold-started
    inside the volatile window (the intersection point itself is never
    applied, so never stored as a rollback-log row) and the chain
    rolled back past its start point before it retained `k` blocks.
- **R4** — The same error gives the recovery for each route, true on
  every boot path:
  - (a) wipe the DB and rebuild, or restart against a node whose chain
    still includes one of the saved points;
  - (b) wipe the indexer DB and start again; a wiped store cold-boots
    from the configured start point, so choose one older than the
    rollback depth (or start from Origin).
  The error makes no other claim about `csStartPoint`.
- **R5** — The `BootMode` Haddock, which today names only the
  `k`-divergence reason for failing closed, is consistent with R3.
- **R6** — The user docs (`docs/usage/utxo-indexer.md`) state the
  cold-only rule and the two routes with their recovery.
- **R7** — A unit check asserts that the message actually raised by
  the warm-boot no-intersection path names both routes. It fails
  against the pre-change text.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| I1 | R1, R2, R5 hold in `Follower.hs` Haddock | any of them is missing or contradicts the code |
| I2 | the raised warm-boot error carries R3 and R4 | either route or its recovery is absent from the raised text |
| I3 | the R7 check observes the raised message (not a detached copy) and is RED on the old text | the check passes on the old text, or its subject is a string the error path does not use |
| I4 | boot-mode selection, cold/warm resume points and the fail-closed decision are unchanged | any of them changes; the warm path stops failing closed |
| I5 | R6 holds | the user docs omit the rule or a route |
| I6 | build, unit, e2e, lint and the release version contract are green | any CI job is red |

## Non-goals

- Making the young-store case recoverable automatically.
- Persisting the intersection point as a rollback-log row.
- Any change to `chain-follower` retention.
