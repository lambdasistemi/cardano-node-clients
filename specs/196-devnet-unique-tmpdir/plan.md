# Plan — 196

## Strategy

Replace the fixed-path allocation in `prepareTmpDir` with an atomic unique
allocation under `getTemporaryDirectory`, and move the allocation inside the
bracket acquire so that every later failure (preparation, spawn, readiness,
callback) is covered by a release that terminates the node first and then
removes exactly the allocated directory. No force-removal of any
caller-independent path remains.

## Constraints

- Unix-socket path limit: `<dir>/node.sock` must stay short for default
  `TMPDIR` values; keep the directory name short (`cardano-e2e-` plus a short
  unique suffix).
- No new exported names; `Setup.hs` and all specs untouched.
- The e2e suite runs in CI twice: inside the Nix sandbox
  (`nix build .#checks.x86_64-linux.e2e`, `TMPDIR=/build`) and on the runner
  (`nix run --quiet .#e2e`, default `/tmp`). The isolation test must hold in
  both.

## Live boundary

Two real `cardano-node` subprocesses started concurrently from one hspec
process; each run performs an N2C query against its own socket.

## Slices

| Slice | Content | Tasks |
|---|---|---|
| S1 | RED isolation/ownership/cleanup e2e test → GREEN allocation + release in `Devnet.hs` → docs | T001–T004 |

One bisect-safe behaviour commit after squash.
