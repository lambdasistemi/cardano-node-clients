# 197 — devnet: run caller work while the restartable node is down

Resolves #197.

## Problem

`withRestartableCardanoNode` hands its callback `restart :: IO ()`, which stops
the node and spawns a new one as one step. A test that must change the node's
database while the node is stopped (restore a snapshot to force a fork, wipe
it, plant a fixture) has no supported point to do so, and does not know where
the database lives. The only workaround is signalling the bracket-owned
process directly.

## User stories

- **US1** — A test author runs an action while the node is guaranteed down,
  between termination and respawn, and the respawned node opens the database
  as that action left it.
- **US2** — The test author learns the run directory and the database
  directory from the API, without guessing paths.
- **US3** — If that action throws, no node process outlives the bracket and
  the run directory is still removed.
- **US4** — Existing callers of `withRestartableCardanoNode`, `withCardanoNode`
  and the `withDevnet` family keep compiling and behaving as before.

## Requirements

- **FR-1** A new bracket, additive to the existing ones, gives its callback the
  socket path, the start time (POSIX ms), the run directory, the database
  directory the node opens, and a restart action that takes a hook
  (`functions-model.md` F-1, `data-model.md` D-1).
- **FR-2** The hooked restart runs, in order: stop the node and wait for its
  process to exit; remove the socket path; run the hook; spawn the node
  against the same run directory, database, socket and genesis; wait until the
  node is ready (same readiness as today).
- **FR-3** While the hook runs, the node process of this run has exited and
  nothing accepts connections on the socket path.
- **FR-4** If the hook throws, the exception propagates out of the restart
  action; no node is spawned for that restart; the bracket's release still
  leaves no node process of this run alive and removes the run directory. A
  later restart inside the same bracket starts the node again.
- **FR-5** `withRestartableCardanoNode`'s signature and its `restart`
  behaviour are unchanged; `restart` is the hooked restart with a hook that
  does nothing. One stop/spawn code path serves both.
- **FR-6** On callback exception the node log tail is still printed before the
  run directory is removed (unchanged behaviour).
- **FR-7** User-facing docs that describe the devnet brackets (README devnet
  component, `docs/` pages) describe the new bracket: what the hook may do,
  that the node is down during it, the exposed paths, and the exception
  behaviour.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 down | inside the hook: no live process of this run's node exists, and a connection attempt to the socket path fails; the same observations made before the restart find the node alive and accepting (positive control) | the node process is alive or the socket accepts during the hook, or the observation cannot detect a live node |
| INV-2 mutation | a database change made in the hook is what the respawned node opens, observed through node-reported chain state; with a hook that does nothing, the same assertion fails | the respawned node shows state the hook removed, or the assertion passes with a do-nothing hook |
| INV-3 no orphan | after a hook throws and the exception leaves the bracket: the exception is the one the hook threw, no process of this run's node is alive, and the run directory no longer exists | a node process of the run survives, the run directory leaks, or a different exception surfaces |
| INV-4 compat | `withRestartableCardanoNode`, `withCardanoNode`, `withDevnet*` signatures unchanged; every existing caller compiles unchanged; `Issue97ReproSpec` and `UTxOIndexerReconnectSpec` stay green | a caller edit is needed or a restart spec turns red |
| INV-5 paths | the exposed database directory is the one passed to the node, inside the exposed run directory, stable across restarts | a different or moving path |
| INV-6 diagnostics | callback exception still prints the node log tail before removal | the tail is lost |
| INV-7 docs | docs state FR-7 | docs omit the new bracket or misstate when the node is down |

Each of INV-1, INV-2, INV-3 has its own assertion in the new e2e spec, and
each assertion is shown able to fail for its own reason (not setup).

## Non-goals

- Separate exported `stopNode` / `startNode` halves (the issue's first
  option).
- Porting the downstream fork/rollback drill or asserting follower rollback
  behaviour.
- Changing `withDevnet*` in `Setup.hs`.

## Success

All CI jobs green on the PR head, with the new spec running in the `e2e`
suite (sandbox and runner) and per-assertion falsification recorded.
