# Plan — #202

## Strategy

A pre-change store is upgraded in place, on request, and online.

1. **Create the families.** With the upgrade requested and the full open
   failing on "Column family not found", open the four pre-change
   families, create `utxo-indexer.asset` and `utxo-indexer.meta`
   through RocksDB's C API, close, and reopen with the full list.
2. **Mark the upgrade.** In one transaction write the rebuild-progress
   key (DM11) in `MetaCol`. From then on the store is in full mode:
   per-op asset maintenance (#200) runs for every follower apply and
   rollback.
3. **Backfill.** A task scoped to the handle's lifetime walks the live
   outputs in key order in bounded transactions, writing each live
   output's asset rows, then removes asset rows whose `TxIn` is not
   live or that differ from the derivation. Each chunk advances the
   progress key in its own transaction. Follower transactions
   interleave; the kv-transactions runner serialises them.
4. **Complete.** The transaction that finishes the backfill deletes the
   progress key and writes the completeness marker. An extraction
   failure deletes the progress key and leaves the marker absent.
5. **Resume.** Any open that finds the progress key resumes step 3,
   flag or not.

Correctness of the interleaving: a `TxIn` live at its chunk's
transaction gets its rows from the backfill; one created later gets them
from maintenance; a spend deletes the rows its stored bytes derive,
whoever wrote them. The sweep removes leftovers of an earlier incomplete
index.

## Decisions

- **D1 Local column-family creation, not a binding change.** The pinned
  `rocksdb-haskell-jprupp` 2.1.7 links `rocksdb_create_column_family`
  but exposes only `Database.RocksDB`; its `DB` record (exported) holds
  the raw handle. A small foreign import in `lib-utxo-indexer` creates
  the two families on an open pre-change store. No pin change.
  Rejected: a change and release of the binding fork plus a pin bump
  for every RocksDB consumer (larger blast radius, cross-repository);
  rebuild into a fresh `--db-path` from genesis (hours to days of
  resync for an index that is a pure function of locally stored bytes).
- **D2 Explicit request.** The upgrade makes the store unopenable by a
  pre-asset binary, so it runs only on `--rebuild-asset-index` / the
  library option, never by default (C2, A-004).
- **D3 Online backfill.** An offline backfill would take the socket
  down for the whole scan, breaking `utxos_at`/`ready`/`await` (A-004).
- **D4 One new reason `rebuilding`** (C1/C3). `ready` is untouched: it
  is #201's.
- **D5 Scope of the request.** It rebuilds only a store whose marker is
  absent; on a complete or empty store it is a no-op (R8). Repair of an
  `inconsistent` store is out of scope.

## Live boundaries

- RocksDB: family creation on a real pre-change directory produced
  through the binding with the four pre-change families; reopen pairs
  names with the GADT order (verified by reopen specs).
- E2E: the daemon restarted on the same `--db-path` against a devnet.

## Slices (each bisect-safe, each OWNER)

| Slice | Scope | Invariants |
|---|---|---|
| S1 library | family creation, progress key, backfill/resume, `rebuilding` unavailability incl. its wire reason, library option; unit specs for restart/resume, upgrade, interleaving, interruption, compatibility | U1–U7, U9, U10 |
| S2 daemon | `--rebuild-asset-index` flag through `DaemonConfig`; E2E restart spec; docs | U8, R10, U4/U7 through the daemon |

## Proof

Gate rows in the runtime gate (not committed): CI jobs `build-gate`,
`build`, `unit`, `e2e`, `lint`, release version contract, and the root
`nix develop --quiet -c just ci`, green on the PR head.
