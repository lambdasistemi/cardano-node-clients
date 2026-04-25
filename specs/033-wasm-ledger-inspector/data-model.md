# Phase 1 Data Model: Structural Tx JSON

**Feature**: 033-wasm-ledger-inspector
**Date**: 2026-04-23

This document defines the shape of the JSON the inspector emits. It is the contract between the decoder and any consumer (golden tests, browser demo, MPFS client). The schema is lossy by design: it surfaces only the fields this feature requires and makes no round-trip guarantee.

---

## Top-level entity

### `StructuralTxJSON`

The single top-level object emitted on stdout per successful decode.

| Field | Type | Presence | Description |
|---|---|---|---|
| `inputs` | `array[TxInRef]` | always | Transaction inputs, ordered as in the tx body. |
| `reference_inputs` | `array[TxInRef]` | always (possibly empty) | Conway reference inputs. |
| `mint` | `MintMap` | always (possibly empty object) | Mint field of the tx body, as policy → asset → quantity. |
| `outputs` | `array[TxOutView]` | always | Transaction outputs, ordered as in the tx body. |
| `redeemers` | `array[RedeemerEntry]` | always (possibly empty) | Conway redeemer entries from the witness set. |

Field order is stable: the JSON is emitted with the key order above, and arrays preserve tx-body order, so fixtures can be diffed byte-for-byte against golden files.

---

## Supporting entities

### `TxInRef`

A reference to a UTxO being spent or read.

| Field | Type | Description |
|---|---|---|
| `tx_id` | `string` (64-char lowercase hex) | 32-byte transaction ID hash. |
| `index` | `integer` (≥ 0) | Output index within the referenced transaction. |

### `TxOutView`

A transaction output, projected to the fields the feature surfaces.

| Field | Type | Presence | Description |
|---|---|---|---|
| `address` | `string` (bech32) | always | Target address, bech32-encoded (mainnet or testnet prefix preserved from the bytes). |
| `value` | `Value` | always | ADA and multi-asset value. |
| `datum` | `DatumView` | always | Datum metadata; see below. `no_datum` variant when the output has none. |
| `script_ref_hash` | `string` (64-char hex) \| null | always | Hash of an attached script reference if present, otherwise `null`. The full script bytes are not surfaced in this feature. |

### `Value`

| Field | Type | Description |
|---|---|---|
| `coin` | `string` (non-negative decimal integer) | ADA amount in lovelace, encoded as string to preserve precision for large values. |
| `assets` | `object{ policy_id: object{ asset_name_hex: string } }` | Multi-asset entries keyed by 28-byte policy ID (hex), then asset name (hex). Quantities encoded as strings. Empty object when no assets. |

### `DatumView`

A tagged union representing the three possible datum states of a Conway output.

- **No datum**
  ```json
  { "kind": "no_datum" }
  ```
- **Datum hash**
  ```json
  { "kind": "datum_hash", "hash": "<64-char hex>" }
  ```
- **Inline datum**
  ```json
  { "kind": "inline_datum", "data": <PlutusData> }
  ```
  where `<PlutusData>` is the Plutus `Data` AST rendered per `PlutusDataView` below.

### `PlutusDataView`

Tagged rendering of the Plutus `Data` AST. Preserves constructor tags, integer values, and byte strings without losing information.

- **Constr**
  ```json
  { "kind": "constr", "tag": <int>, "fields": [<PlutusDataView>...] }
  ```
- **Map**
  ```json
  { "kind": "map", "entries": [{ "key": <PlutusDataView>, "value": <PlutusDataView> }...] }
  ```
- **List**
  ```json
  { "kind": "list", "items": [<PlutusDataView>...] }
  ```
- **Integer**
  ```json
  { "kind": "i", "value": "<decimal string>" }
  ```
  String-encoded to handle arbitrary-precision integers that do not fit in IEEE 754.
- **ByteString**
  ```json
  { "kind": "b", "value": "<lowercase hex>" }
  ```

### `MintMap`

```json
{
  "<policy_id_hex>": {
    "<asset_name_hex>": "<signed decimal string>"
  }
}
```

Quantities are signed decimal strings to accommodate burns (negative) and large positive mints. An empty `mint` field in the tx body is rendered as `{}`.

### `RedeemerEntry`

A single Conway redeemer entry (`tag`, `index`, `data`, `ex_units`).

| Field | Type | Description |
|---|---|---|
| `tag` | `string` (enum) | `"spend"` \| `"mint"` \| `"cert"` \| `"reward"` \| `"vote"` \| `"propose"`. |
| `index` | `integer` (≥ 0) | Index into the tagged collection (e.g. input index for `spend`). |
| `data` | `PlutusDataView` | Redeemer payload as rendered Plutus `Data`. |
| `ex_units` | `ExUnits` | Execution budget. |

### `ExUnits`

| Field | Type | Description |
|---|---|---|
| `mem` | `string` (non-negative decimal) | Memory budget. |
| `cpu` | `string` (non-negative decimal) | CPU-step budget. |

---

## Validation rules (derived from FRs)

1. **Presence** — `inputs`, `reference_inputs`, `mint`, `outputs`, `redeemers` keys MUST always be present. Empty collections render as `[]` or `{}`, never omitted.
2. **Stable ordering** — arrays preserve tx-body order; object keys within outputs / values / redeemers follow the schema's declared order (enforced by the decoder's `aeson` encoding path).
3. **Era fidelity** — the decoder MUST only accept Conway-era txs; non-Conway input yields FR-011 error (non-zero exit, single-line stderr message, no partial JSON).
4. **Precision** — all numeric fields that can exceed IEEE 754 safe integer range (coin, asset quantities, mem, cpu, Plutus integers) MUST be strings.
5. **Hex encoding** — all hash-like byte strings MUST be lowercase hex without prefix.
6. **No cryptographic claims** — the JSON contains no signatures, no witness verification outcomes, no script hashes beyond `script_ref_hash`. The schema does not let a consumer conclude anything about tx validity; it is a structural view only.

---

## Error output

On decode failure (FR-011), the inspector writes nothing to stdout and one line to stderr following this shape:

```
<category>: <detail>
```

with `<category>` drawn from a fixed set:

- `era_mismatch` — the CBOR parsed as a non-Conway-era tx.
- `malformed_cbor` — the bytes did not parse as CBOR at all.
- `structural_error` — CBOR parsed but does not match the Conway tx schema at some point.

Exit status is non-zero. No partial JSON is ever emitted.

---

## Relationship to downstream consumers

- **Golden tests** consume `StructuralTxJSON` verbatim, comparing byte-for-byte against `test/fixtures/conway/*.expected.json`.
- **Browser demo** (`docs/inspector/inspector.js`) captures stdout, parses once as JSON, and renders in a `<pre>` block.
- **MPFS client** (future consumer, in a separate repository) will use the same JSON (or the underlying Haskell types via library import, not yet exposed in this feature) to bind a proof bundle to its tx.
