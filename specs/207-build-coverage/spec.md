# Spec — #207 store records its build coverage

Parent: #199. Issue: #207 (acceptance frozen in the issue body).
Builds on #201 (`specs/201-asset-coverage/`) and #202
(`specs/202-asset-index-upgrade/`, DM11).

## User story

As a library consumer who builds a UTxO store with a start point or an
address filter, when I reopen that store I either get the coverage it
was built with or an explicit refusal; an asset answer never claims
coverage the store does not have.

## Requirements

- **R1 Record at creation.** The first follower session over an empty
  store records the build coverage (start point, interest set) in
  `MetaCol` under a new key, alongside the asset-index keys.
- **R2 Refuse a mismatch.** A follower session over a store whose
  recorded coverage differs from the session's configuration (start
  point or interest set, including a different address set) refuses
  before any chain-sync with an explicit error naming both coverages.
  The store is left untouched.
- **R3 Answer reads the record.** The asset answer's `coverage` and
  `limits` derive from the store's recorded coverage, not from the
  serving configuration.
- **R4 Unknown, never assumed.** A non-empty store without a record
  (created before this change, or a degraded/upgraded pre-asset store)
  serves with coverage `unknown`: `coverage.start` and
  `coverage.addresses` are `"unknown"` and `limits` names
  `coverage_unknown`. No record is written into it (C2).
- **R5 Corrupt record.** A record that does not decode (unknown version,
  malformed bytes) refuses like R2 and is never rewritten.
- **R6 Compatibility (C1/C4).** Wire field names and shape unchanged;
  only values are added. `utxos_at`, `ready`, `await` bytes, both error
  answers and the v1 success fields are unchanged. The shipped daemon
  (origin, `IndexAll`) on a store it creates answers exactly as before.
- **R7 Docs.** `docs/usage/utxo-indexer.md` states what is recorded,
  when, the refusal, and `unknown`.

## Wire additions (C1, success answer only)

- `coverage.start`: adds `"unknown"`.
- `coverage.addresses`: adds `"unknown"`.
- `limits`: adds `coverage_unknown`, ordered first:
  `coverage_unknown, address_filter, partial_history, catching_up,
  disconnected, stale`.

## Invariants (stable IDs)

| ID | Holds when | Fails observably when |
|---|---|---|
| V1 | first session on an empty store writes the record, which decodes to the session's start point and interest set (both backends) | no record, or it decodes to anything else |
| V2 | reopen with the same configuration serves; answer coverage equals the record | refusal, or other coverage |
| V3 | reopen of a non-empty recorded store with a changed start point (none↔point, point↔other point) refuses before chain-sync; the follower action never runs; store bytes unchanged (both backends) | it serves, or any store byte changes |
| V4 | as V3 for a changed interest set (all↔set, set A↔set B) | as V3 |
| V5 | a non-empty store without a record answers `unknown`/`unknown` with `coverage_unknown` in `limits`, under any configuration including the daemon's; no record is written | `origin`/`all`/`filtered`/a point is reported, or the key appears |
| V6 | `limits`: `coverage_unknown` iff coverage unknown; `address_filter` iff `filtered`; `partial_history` iff start is a point (never for `unknown`); freshness limits unchanged; order as above | any other set or order |
| V7 | an undecodable record refuses like V3 and keeps its bytes | it serves, or the bytes change |
| V8 | once present, the record key is never rewritten or deleted by any path | any write to it after creation |
| V9 | `utxos_at`/`ready`/`await` bytes, both error answers, v1 fields unchanged; a fresh daemon store answers `origin`/`all` with the limits it gave before | any byte or value differs |
| V10 | a degraded (four-family) store yields `unknown`, never a record it cannot hold | it reports a recorded coverage |

## Out of scope

Writing a record into an existing store (no explicit path is added);
history-store coverage; fault injection (#203); e2e harness (#212).
