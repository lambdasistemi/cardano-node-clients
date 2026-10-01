# Data model — 196

## D-1 Run working directory

| Field | Value |
|---|---|
| root | `getTemporaryDirectory` (honours `TMPDIR`) |
| name | `cardano-e2e-` prefix plus a unique suffix chosen atomically at creation |
| contents | genesis files, `delegate-keys/`, `db/`, `node.log`, `node.sock` |
| created by | the run itself; creation fails rather than reuse an existing path |
| lifetime | from allocation inside bracket acquire to bracket release |
| restart | same directory, `db/` and `node.sock` across restarts |
| removal | release only; after node termination; removes this directory only |

State invariants: INV-1, INV-2, INV-3, INV-6 (see `spec.md`).
