# Plan — #200

## Strategy

The asset index is a new column of the UTxO indexer's own `Cols`,
maintained inside the single per-op apply step that already writes
`TxInCol`/`AddressIndex`/`ObservationCol`. Because restore, follow and
rollback all funnel through that step inside the existing block
transaction, R7 holds by placement, not by new plumbing.

Asset rows are a pure function of each live output's stored bytes. The
apply step extracts the output's multi-asset map from the stored CBOR on
create, and re-extracts it from the stored output on spend to delete
exactly the rows it wrote. Rollback inverses therefore keep their
create/spend shape; only spend inverses gain provenance (R8).

Extraction is ledger-free, over the stable CDDL output grammar
(legacy array and post-Alonzo map; value = coin | [coin, multiasset];
datum_hash / datum_option). `lib-utxo-indexer` stays ledger-decoupled;
the unit tests cross-check the decoder against the ledger's own decoding.

The indexed point is read, in the query's own transaction, as the newest
`RollbackCol` row carrying block-hash metadata. No new point column.
Transactions are serialised by the kv-transactions runner lock, so one
transaction is one snapshot (R6).

Completeness (R9/C3) is a marker in a new metadata column, written only
when the store is opened empty. A pre-change store never gains it; an
extraction failure deletes it in the failing transaction. #202 owns
versioning/migration and will extend this column (clean seam).

## Decisions

- **D1 #195 is not a dependency.** The asset index is internal to the
  UTxO indexer's `Cols` and maintained by `liveUtxoHandler`'s apply step.
  No consumer-registered column is needed, so the monomorphic
  `csHandlers` seam does not block #200.
- **D2 Ledger-free extraction in `lib-utxo-indexer`.** Rejected: an
  extractor injected through every handle constructor (breaks or forks
  the embedder API used by cardano-tx-tools); a fourth field on
  `UtxoCreate` (breaking constructor change).
- **D3 Spend inverses carry provenance** via an additive `UtxoOp`
  constructor and rollback-log tag 2. Old tag-0/1 rows still decode.
  Effect on `await` approved (spec R8a): exact creation point after a
  rollback restoration; every other `await` case byte-identical.
- **D4 Point from `RollbackCol`.** A store with no following row (empty,
  or restoration-only) has no point → `no_indexed_point`.
- **D6 Degraded open of pre-change stores** (see Live boundaries):
  chosen because the pinned `rocksdb-haskell-jprupp` exposes neither
  `create_missing_column_families` nor column-family creation. Rejected:
  refusing to open pre-change stores (breaks existing `utxos_at`/`ready`/
  `await` deployments until #202).
- **D5 Wire request key `utxos_with_asset`**, camelCase response fields
  matching `await`/`ready`, decimal-string quantity.

## Live boundaries

- RocksDB open of a pre-change directory (D6): the pinned RocksDB binding
  cannot create missing column families, so the store opens with its four
  pre-change families when, and only when, the full open fails with
  "Column family not found". Other open errors propagate unchanged; a
  failed fallback reports the original error; errors from the caller's own
  work are never reclassified. On such a store `utxos_at`, `ready` and
  `await` keep working (including the R8a correction for new rows), asset
  maintenance is skipped on every handler path, and the asset query
  answers `absent`. Adding the families (migration) is #202; a store
  created by this change cannot be opened by a pre-change binary.
- Column-family name ↔ GADT pairing (`mkColumns` lex order) must hold for
  the two new families; verified by reopen tests, not by inspection.
- E2E: a real devnet node produces mint, transfer, split, spend and burn
  transactions under a native-script policy; the daemon's socket answers.

## Slices (each bisect-safe, each OWNER)

| Slice | Scope | Invariants | Releases |
|---|---|---|---|
| S1 storage | `lib-utxo-indexer`: asset/metadata columns + codecs, output view decoder, apply/inverse maintenance, provenance-carrying spend inverse, completeness marker, typed read op; unit specs (in-memory and RocksDB, replay, divergent, rollback provenance, concurrency, pre-change store, decoder vs ledger) | I1–I7, I9 (decoder) | C2 |
| S2 wire | `lib` server request/response + error codes, docs, wire/parser/golden specs, E2E devnet spec | I3, I8, I9 (wire), I10, plus I1/I4/I7 end-to-end | C1 |

S1 ships no socket change; S2 depends on S1's typed op only.

## Proof

`nix develop --quiet -c just ci` locally; CI jobs `build-gate`, `build`,
`unit`, `e2e`, `lint` green on the PR head. Gate rows in the runtime
gate manifest (not committed).
