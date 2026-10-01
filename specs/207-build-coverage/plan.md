# Plan — #207

## Strategy

The store, not the process, owns its coverage.

1. `lib-utxo-indexer` gains a build-coverage record in `MetaCol`
   (data-model DM12) and one handle operation that, in a single
   transaction, reads the record and decides: empty store without
   record → write it, recorded; record equal → recorded; record
   different or undecodable → refusal; non-empty without record (or
   degraded) → unrecorded.
2. The follower calls it once per `withChainSyncFollower*` bracket,
   before the chain-sync thread starts (not per reconnect). A refusal
   raises an exception; the caller's action never runs. The outcome is
   exposed on `FollowerHandle`.
3. `Disclosure` maps the store outcome to wire coverage, adds the
   `unknown` values and the `coverage_unknown` limit. The daemon builds
   its disclosure from the follower handle's outcome.
4. Docs replace "coverage is the configuration of the running process".

## Decisions

- **D1 Refuse every mismatch.** Filter mismatch would mix coverages in
  one store; start-point mismatch is only safe on a pure warm boot and
  not on the history-attached route that consults it. One rule, one
  error. A-004 is not touched: stores without a record still open.
- **D2 Record only on an empty store.** "Empty" = no `TxInCol` row and
  no rollback-log entry (the #202 marker's emptiness rule). Coverage of
  an empty store is true by construction; of a non-empty one it is not
  knowable, so it is `unknown` (C3) and nothing is written (C2).
- **D3 Exact record.** The record holds the full address set, not a
  digest: exact comparison, no new dependency.
- **D4 Store-side decision in one transaction.** Same atomicity as the
  #202 boot decision; works identically on both backends.
- **D5 `followerCoverage` is deleted** (sole production caller swaps to
  the recorded value); its spec rows move to the store-outcome mapping.
- **D6 Shipped daemon unchanged** in configuration and flags.

## Live boundaries

RocksDB reopen = close and reopen the directory; in-memory reopen = a
second follower bracket over the same handle. Both run through
`withChainSyncFollowerUsing` with an injected runner, so refusal is
observed with no node.

## Slices

| Slice | Scope | Invariants | Mode |
|---|---|---|---|
| S1 | record + decision (lib-utxo-indexer), follower call and refusal, disclosure `unknown`, daemon wiring, specs, docs | V1–V10 | OWNER |

One slice: the record is only observable through the answer and the
refusal together.

## Proof

Runtime gate (not committed): CI `build-gate`, release version
contract, `build`, `unit`, `e2e`, `lint`, and root
`nix develop --quiet -c just ci`, green on the PR head.
