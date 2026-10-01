# Spec — #200 asset query on the utxo-indexer socket

Parent: #199. Issue: #200 (acceptance frozen in the issue body).

## User story

As an integrator, I send the running `utxo-indexer` daemon a policy ID and
an asset name and get back every live output holding that asset, with its
stored ledger output bytes, quantity and creation point, read from one
consistent indexed point.

## Requirements

- **R1 Typed API.** `lib-utxo-indexer` exposes an additive read
  operation: policy ID (exactly 28 bytes) + asset name (0–32 raw bytes,
  no text assumption) → either an explicit unavailability or a snapshot.
  No address input.
- **R2 Wire request.** The socket protocol gains one additive request
  (schema below). `utxos_at`, `ready`, `await` keep their request and
  response bytes (C4).
- **R3 All matches.** Every live output holding the asset is returned,
  each with its quantity. No first-match, no uniqueness assumption.
  Ascending `TxIn` order.
- **R4 Result fields.** Each match carries: output reference, the stored
  output bytes byte-identical to what `utxos_at` returns for the same
  `TxIn`, the quantity, the creation slot and block hash, and a datum
  view derived from those same bytes.
- **R5 Datum honesty.** Datum view is `none`, `hash` (the 32-byte hash
  the output carries) or `inline` (the exact inline-datum CBOR bytes, a
  byte-for-byte slice of the stored output). Never synthesised.
- **R6 Indexed point.** The response carries the point (slot, block hash)
  of the newest applied block the store reflects. Matches, provenance and
  point are read in one storage transaction.
- **R7 Transactional maintenance.** Asset-index writes, their rollback
  inverses and provenance share the existing block transaction for every
  path: restore, follow, rollback, replay, divergent block.
- **R8 Creation provenance survives rollback.** An output restored by a
  rollback reports its original creation slot/hash.
- **R9 Unavailable is explicit (C3).** A store without a complete asset
  index (created before this change, or whose index lost completeness)
  or with no indexed point answers the asset query with an explicit
  unavailability, never with an empty or partial match list.
- **R8a `await` correction (epic ruling A-001).** After a rollback
  restores a spent output, `await` and the asset query both report its
  original creation slot/hash. Rollback-log rows written before this
  change (tags 0/1) still decode and apply with their old behaviour and
  are never rewritten. Every other `await` case is byte-identical.
- **R10 Docs.** `docs/usage/utxo-indexer.md` documents the request with a
  runnable example, every response field, error codes, datum
  availability, and the `await` correction (R8a).

## Invariants (stable IDs)

| ID | Holds when | Fails observably when |
|---|---|---|
| I1 | asset rows = exactly {(policy, name, txIn) ↦ qty} derived from the live outputs' stored bytes, after any apply/rollback sequence | a spent/burnt output still matches, a live holder is missing, or a quantity differs |
| I2 | in-memory and RocksDB backends give identical asset answers for the same block sequence | answers differ |
| I3 | `txout` in a match equals the `AddressIndex` bytes for that `TxIn` | bytes differ |
| I4 | `created` equals the (slot, hash) of the block that created the output, including after rollback restoration | rollback slot or any other point reported |
| I5 | every response's matches equal the model state at the response's `point` under concurrent apply/rollback | a mixed-point response |
| I6 | replay of an applied block leaves asset rows unchanged; a divergent block (`ApplyConflict`) leaves them unchanged | rows change |
| I7 | a pre-change store, or one with no indexed point, never answers with `utxos` | an empty/partial list is returned |
| I8 | `utxos_at`/`ready`/`await` request and response bytes unchanged, except `await` after a rollback restoration, which now reports the true creation slot/hash (R8a) | any other byte differs |
| I9 | datum view matches the ledger's own decoding of the same output; inline bytes are a slice of `txout` | mismatch or bytes not found in `txout` |
| I10 | malformed requests (policy ≠ 28 bytes, name > 32 bytes, bad hex, missing field) get `invalid_asset_query`, never a match list | accepted or answered with data |

## Wire schema v1 (C1)

Request (one line, one connection, as the existing endpoints):

```json
{"utxos_with_asset": {"policy_id": "<56 hex>", "asset_name": "<0..64 hex>"}}
```

Success response:

```json
{"point": {"slot": 1234, "blockHash": "<hex>"},
 "utxos": [
   {"txin": "<txid hex>#<ix>",
    "txout": "<base16 stored output CBOR>",
    "quantity": "<decimal string>",
    "created": {"slot": 1200, "blockHash": "<hex>"},
    "datum": {"kind": "none"}
            | {"kind": "hash", "hash": "<64 hex>"}
            | {"kind": "inline", "cbor": "<hex>"}}
 ]}
```

Errors (the existing `{"error": ...}` shape, stable code + detail):

```json
{"error": "invalid_asset_query", "detail": "<human text>"}
{"error": "asset_index_unavailable", "reason": "absent" | "no_indexed_point" | "inconsistent"}
```

Hex input is case-insensitive; output is lower-case. `quantity` is a
decimal string so no consumer loses precision. Siblings #201/#202 add
fields only; v1 fields never change meaning.

## Out of scope

Network identity, coverage/start-point/filter limits, freshness (#201);
close/reopen/resume, storage versioning, migration and rebuild (#202);
fault-injection checks (#203). Address-filtered library embedders
(`IndexAddressSet`) index only filtered outputs; disclosing that coverage
is #201. The shipped daemon indexes everything (`IndexAll`).
