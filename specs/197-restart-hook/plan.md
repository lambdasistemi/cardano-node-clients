# Plan — 197

## Strategy

Choose the issue's second option: keep the restart atomic but take a hook run
after termination and before spawn. Add one new bracket that exposes a record
(socket, start time, run directory, database directory, hooked restart). Re-
express `withRestartableCardanoNode` through it so there is a single node
lifecycle; `restart` becomes the hooked restart with a do-nothing hook.

## Constraints

- No change to existing exported signatures, `Setup.hs`, or existing specs.
- The bracket stays the sole owner of the node process; the hook never sees a
  process handle.
- The e2e suite runs in CI inside the Nix sandbox (`nix build
  .#checks.x86_64-linux.e2e`) and on the runner (`nix run --quiet .#e2e`); the
  new spec must hold in both.
- Devnet: 0.1 s slots, `activeSlotsCoeff` 1.0 — block height grows ~10/s,
  which makes a database rewind observable through the node's tip.

## Live boundary

One real `cardano-node` subprocess, stopped and respawned inside one bracket;
observations are made against the live process table, the socket, and N2C
queries to the respawned node.

## Slices

| Slice | Content | Tasks |
|---|---|---|
| S1 | RED e2e spec for INV-1..INV-3 → GREEN hooked restart in `Devnet.hs` → docs | T001–T004 |

One bisect-safe behaviour commit after squash.
