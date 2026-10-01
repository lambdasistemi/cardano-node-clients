# Spec — #202 asset index across restart and upgrade

Parent: #199. Issue: #202 (acceptance frozen in the issue body). Builds
on #200 (`specs/200-asset-query/`, plan D6).

## User story

As an operator, I restart or upgrade the `utxo-indexer` daemon and the
asset query keeps giving the same correct answers; a store created
before the asset index gets an explicit, documented upgrade instead of
wrong answers, and `utxos_at`, `ready` and `await` keep working
throughout.

## Requirements

- **R1 Restart preserves the asset view.** Closing and reopening a
  RocksDB store, then resuming the chain from the store's own
  intersection points, yields the same asset answers (matches,
  quantities, creation provenance) as a store that never closed and was
  fed the same blocks.
- **R2 Explicit upgrade.** A pre-change store (four column families) or
  a store whose index is not complete is upgraded only when the
  operator asks for it: CLI flag `--rebuild-asset-index`, library
  option on the RocksDB constructors. Without the request the store
  opens and behaves exactly as today (D6, ruling A-004).
- **R3 In-place, from local data.** The upgrade adds the missing column
  families and derives the asset index from the store's own live
  outputs. No chain resync, no new `--db-path`.
- **R4 Online.** During the upgrade the daemon follows the chain and
  serves `utxos_at`, `ready` and `await` as usual; follower blocks and
  rollbacks interleave with the upgrade at any transaction boundary.
- **R5 No false answer (C3).** Until the index is complete the asset
  query answers `asset_index_unavailable` with the new reason
  `rebuilding` while an upgrade is in progress, `absent` when none is.
  The completeness marker is written only when the index is complete.
- **R6 Restart-safe upgrade.** An upgrade interrupted at any point
  (crash, stop) continues at the next open of the store, with or
  without the flag, and still reaches a complete index.
- **R7 No silent rewrite (C2).** Existing `TxInCol`, `AddressIndex`,
  `ObservationCol` and rollback-log rows are never rewritten or deleted
  by the upgrade. Only `AssetIndex` and `MetaCol` rows are written or
  removed, and only under R2.
- **R8 Idempotent request.** The flag on a store whose index is
  complete, or on a new empty store, changes nothing.
- **R9 Compatibility (C4).** `utxos_at`, `ready` and `await` request
  and response bytes are the same before, during and after the upgrade
  for the same store contents.
- **R10 Docs.** `docs/usage/utxo-indexer.md` documents restart
  behaviour, the upgrade procedure, what each request answers during
  it, the `rebuilding` reason, and that the upgrade is one-way: a store
  opened by this version with the asset families can no longer be
  opened by a binary that predates the asset index.

## Wire (C1)

`asset_index_unavailable.reason` gains one value, `rebuilding`. No other
field or value changes.

## Invariants (stable IDs)

| ID | Holds when | Fails observably when |
|---|---|---|
| U1 | after close/reopen/resume the asset answers equal those of a never-closed store fed the same blocks (RocksDB) | any match, quantity, `created` or point differs |
| U2 | a completed upgrade leaves asset rows = exactly the rows derived from the live outputs' stored bytes (DM10 of #200), whatever follower applies and rollbacks interleaved | a live holder missing, a spent output matching, a quantity differing |
| U3 | the asset query never answers a match list while the marker is absent; during an upgrade it answers `rebuilding` | a list (empty or not) before completion, or `absent` while an upgrade is in progress |
| U4 | without the upgrade request, a pre-change store opens degraded and behaves as in #200 | the store fails to open, changes families, or gains rows |
| U5 | an upgrade interrupted at any transaction boundary completes on a later open and satisfies U2 | it stays `rebuilding` forever, restarts lose rows, or the marker appears early |
| U6 | the upgrade writes no row outside `AssetIndex`/`MetaCol` | any byte of the four pre-change families changes because of the upgrade |
| U7 | `utxos_at`/`await` response bytes and `ready` answers for the same store contents are identical before, during and after the upgrade | any byte differs |
| U8 | the E2E daemon, restarted on the same `--db-path` against a devnet, answers the asset query with the same holders before and after restart | holders differ or the restarted daemon answers unavailable after it is ready |
| U9 | the flag on a complete or new store is a no-op | marker removed, rows rewritten, or `rebuilding` reported |
| U10 | an output whose bytes fail extraction during the upgrade leaves the index incomplete (`absent`), never complete | marker written over an incomplete index |
