# Data model — #200 (C2: asset columns and inverse encoding)

All integers big-endian. Existing encodings (TxIn = 32-byte id || 2-byte
ix; SlotNo = 8 bytes; length prefixes = 4 bytes) are reused unchanged.

## Identity and keys

- **DM1 PolicyId** — exactly 28 bytes. Construction from any other
  length is rejected.
- **DM2 AssetName** — 0..32 raw bytes, no text interpretation. Longer is
  rejected. Empty is valid and distinct from every non-empty name.
- **DM3 AssetKey** = (PolicyId, AssetName, TxIn), encoded
  `policyId(28) || nameLen(1) || name || txIn(34)`. The length byte makes
  `policyId || nameLen || name` an exact prefix for one asset: a seek
  there never yields a different policy, a longer name, or a shorter
  name. Decoding rejects trailing or missing bytes.

## Output view (derived, never stored)

- **DM4 Asset quantities** — the output's multi-asset map as
  (PolicyId, AssetName, quantity) with quantity a positive `Word64`.
  Coin-only and Byron-shaped outputs yield none. Zero-quantity entries,
  if the bytes contain any, are not rows.
- **DM5 DatumView** — `NoDatum` | `DatumHash` (32 bytes as carried) |
  `InlineDatum` (the CBOR bytes inside the tag-24 wrapper, exactly as
  they appear in the stored output). Undecodable output bytes are a
  decode error, never an empty view.

## Inverse op

- **DM6 UtxoRestore** txIn addr txOut createdSlot createdBlockHash —
  produced only as the inverse of a spend (or of a re-create over a live
  `TxIn`); applying it re-creates the output with the given provenance.
  Block extraction never produces it. `UtxoCreate`/`UtxoSpend` keep their
  shape and meaning.
- **DM9 Rollback-log op encoding**, extending the existing list form:
  - tag 0: `0 || txIn(34) || addrLen || addr || txOutLen || txOut` (unchanged)
  - tag 1: `1 || txIn(34)` (unchanged)
  - tag 2: `2 || txIn(34) || addrLen || addr || txOutLen || txOut || slot(8) || hashLen || hash`
  Existing rows (tags 0/1) keep decoding; any other tag is a decode
  failure, as today.

## Columns

| ID | Column | Key → value | RocksDB family |
|---|---|---|---|
| DM7 | `AssetIndex` | AssetKey → quantity `Word64` (8 bytes) | `utxo-indexer.asset` |
| DM8 | `MetaCol` | metadata key → value bytes | `utxo-indexer.meta` |

DM8 holds one key in v1: `asset-index` (ASCII) → `0x01` meaning "this
store's asset index is complete since the store was created". #202 owns
any further keys and versions.

## State invariants

- **DM10** For every live `TxIn` (present in `TxInCol`), its rows in
  `AssetIndex` are exactly DM4 of its `AddressIndex` bytes, and it has an
  `ObservationCol` entry. No `AssetIndex` row exists for a non-live
  `TxIn`. Holds after every committed transaction.
- The `asset-index` marker is written only when a store is opened with
  empty `TxInCol` and empty `RollbackCol`; a store opened non-empty
  without it never gains it in #200.
- An output whose bytes fail DM4/DM5 decoding during apply or spend
  deletes the marker in that same transaction; maintenance continues.
- Indexed point: the newest `RollbackCol` row with block-hash metadata.
  None → no point.
- Asset query outcome: unavailable `absent` (no marker),
  `no_indexed_point`, `inconsistent` (an `AssetIndex` row whose `TxIn`
  lacks `TxInCol`, `AddressIndex` or `ObservationCol` data); otherwise
  the point plus all matches in ascending `TxIn` order.
