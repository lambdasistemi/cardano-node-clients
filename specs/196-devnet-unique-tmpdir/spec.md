# 196 — devnet: unique per-run working directory

Resolves #196 and its duplicate #189.

## Problem

`withRestartableCardanoNode` (and therefore `withCardanoNode`, `withDevnet`,
`withDevnetConfig`, `withDevnetFromGenesis`) places its working directory at the
fixed path `<getTemporaryDirectory>/cardano-e2e`, force-removes that path on
entry, and force-removes it again on exit. Two runs on one host share the
directory: the second entrant deletes the first one's live node database and
socket.

## User stories

- **US1** — A developer or CI runner starts two devnet runs on one host at the
  same time; both complete against their own live node.
- **US2** — A consumer that already calls the devnet brackets keeps compiling
  and behaving as before, with no source change.
- **US3** — Nothing a run did not create is ever deleted by that run.

## Requirements

- **FR-1** Each run allocates a new working directory under
  `getTemporaryDirectory` (so `TMPDIR` remains the explicit root override). The
  allocation never reuses a path that existed before the call.
- **FR-2** A run removes only the directory it allocated. No path that existed
  before the call — including a legacy `<tmp>/cardano-e2e` — is removed or
  modified.
- **FR-3** The allocated directory is removed on every exit path after its
  creation: normal return, callback exception, asynchronous exception, and
  failure during preparation, node spawn or readiness wait. Removal happens
  after the node process has been terminated.
- **FR-4** Restart (`withRestartableCardanoNode`'s `restart`) keeps the same
  directory, database and socket path for the life of the run.
- **FR-5** Exported signatures of `withCardanoNode`,
  `withRestartableCardanoNode`, `withDevnet`, `withDevnetConfig`,
  `withDevnetFromGenesis` are unchanged.
- **FR-6** On callback exception the node log is still printed before the
  directory is removed.
- **FR-7** User-facing docs state the per-run directory, its root, its removal,
  and that concurrent runs are isolated.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 unique | two runs, concurrent or sequential, observe different working directories, each absent before its call | two runs share a directory, or a run reuses a pre-existing path |
| INV-2 ownership | a directory/file pre-existing at call time (incl. `<tmp>/cardano-e2e`) is byte-identical after the run | it is removed or modified |
| INV-3 cleanup | after the bracket returns or throws, the run's directory no longer exists and no node process from it is alive | the directory leaks on any exit path, or is removed while its node runs |
| INV-4 isolation | two concurrent runs in one process each execute an N2C round-trip against their own node and both succeed; the same test is RED on the fixed-path base for the isolation reason | either run fails, or the test cannot fail on the fixed path |
| INV-5 compat | every existing caller in `e2e-test/**` and `test/**` compiles unchanged | a caller edit is required |
| INV-6 restart | restart specs (`Issue97ReproSpec`, `UTxOIndexerReconnectSpec`) stay green | restart moves or loses the directory |
| INV-7 diagnostics | callback exception still prints the node log tail | log is gone before it is printed |
| INV-8 docs | docs describe FR-7 | docs still imply a fixed path or say nothing about concurrency |

## Non-goals

- An explicit caller-supplied working-directory variant (the root override is
  `TMPDIR`).
- #197 (stop/start hook in `withRestartableCardanoNode`); the restart closure
  shape must stay open to it.
- Deleting downstream serialize-by-convention workarounds (downstream repos).

## Success

All CI jobs green on the PR head, with the INV-4 test running in the `e2e`
suite and its RED recorded against the fixed-path base.
