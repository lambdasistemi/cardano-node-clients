# Plan — #201

## Strategy

The storage read of #200 is untouched: `assetUtxos` still returns one
snapshot. Everything new is the server's to state, from two sources
handed to `runServer` by its caller:

- a fixed disclosure (network magic, coverage, ready threshold, stale
  bound), built by the daemon from the same `ChainSyncConfig` it gives
  the follower, so coverage cannot drift from what runs;
- the live readiness reader the daemon already passes, whose
  `ReadyStatus` gains the follower's last-progress time.

After the storage read, the server samples readiness and the clock and
classifies freshness with one pure function against the snapshot's own
point. `limits` is a pure function of coverage and freshness. The
`ready` encoding does not change.

## Decisions

- **D1** One pure classifier for freshness and limits, so every
  combination is checkable without a socket or a node.
- **D2** `runServer` takes the disclosure as a new argument. A library
  caller cannot serve asset answers without stating coverage; the
  breaking signature change is preferred over a default that would
  claim full coverage.
- **D3** Coverage from the follower configuration (spec Decisions).
  The daemon derives it with one function over `ChainSyncConfig`.
- **D4** `ReadyStatus` gains the last-progress time; its JSON encoding
  is unchanged (C4).
- **D5** No change to `Indexer.hs`, `Columns.hs` or the follower.

## Live boundaries

- Freshness is in-process state read after the storage transaction;
  spec R5 states the relation.
- E2E: a devnet node (restartable harness) serves the synced case; the
  same daemon with the node stopped serves the disconnected case from
  its cached store. `stale` and `catching_up` are driven through the
  real socket with an injected readiness reader.

## Slices

| Slice | Scope | Invariants | Releases |
|---|---|---|---|
| S1 | disclosure types and classifier, `ReadyStatus` last progress, server wire additions, daemon derivation and flag, unit/socket/E2E specs, docs | J1–J8 | C1 additions |

One slice: the fields are only observable together on the wire, and
each part alone ships no behaviour.

## Proof

Frozen gate rows (CI commands) in the runtime gate manifest, not
committed. `nix develop --quiet -c just ci` plus CI `build-gate`,
`build`, `unit`, `e2e`, `lint` green on the PR head.
