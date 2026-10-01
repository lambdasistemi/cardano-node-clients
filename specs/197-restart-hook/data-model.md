# Data model — 197

## D-1 Restartable node handle (record given to the callback of F-1)

| Field | Meaning | Invariant |
|---|---|---|
| socket path | `<runDir>/node.sock`, same across restarts | absent while a hook runs (FR-2) |
| start time | POSIX ms of genesis start, as today | — |
| run directory | the per-run directory from `allocateRunDir` | removed by bracket release only |
| database directory | the `--database-path` given to every spawn, inside the run directory | INV-5 |
| hooked restart | stop → remove socket → hook → spawn → ready | FR-2..FR-4, INV-1..INV-3 |

## D-2 Node lifecycle state (internal)

The bracket holds the current node (process, log handle). States: `running`
→ (hooked restart) `stopped` → hook → `running`; hook exception leaves
`stopped`. Release from either state terminates (no-op when stopped) and
waits, then the outer release removes the run directory. No spawned process
may be unreachable from the release on any exit path (INV-3).
