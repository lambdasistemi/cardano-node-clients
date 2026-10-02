# Atomic socket multi-read — #220 proposal

Status: intake proposal, pending epic-owner acceptance; no implementation mandate.
Authority: cardano-node-clients #220, parent #199, library dependency #210/#217.
Inspected base: `1b3bf8b03d44de7db073b766c4a18b1065febfcf`.
The former #210 S2 requested-point plan does not govern this feature.

## User stories

1. A socket client sends several address and asset lookups in one request.
   It receives every answer from one `readView` snapshot and learns its slot
   and block hash, so transaction decisions do not combine index states.
2. A client sees an explicit whole-request refusal when no indexed point
   exists or the asset index is unavailable/degraded, including address-only
   batches. An unavailable store never masquerades as a successful empty read.
3. A client already using `utxos_at`, `ready`, `await` or `utxos_with_asset`
   sends and receives exactly the same bytes after this additive feature.
4. A client receives coherent answers while the index changes, so it can trust
   that every answer describes the reported indexed point when deciding which
   transaction inputs to use.
5. An integrator reads user docs explaining the batch request, response,
   indexed point, ordered answers and every unavailability reason.

## Proposed wire contract

One NDJSON request line, one response line ending in LF, then EOF, as today.
New top-level request key: `read_view`; its value is a nonempty query array.
Each query object has exactly one of the existing lookup keys:

```json
{"read_view":[{"utxos_at":"<address-hex>"},{"utxos_with_asset":{"policy_id":"<56-hex>","asset_name":"<0-to-64-hex>"}},{"utxos_at":"<address-hex>"}]}
```

Success has exactly `point` and `results`; no per-result indexed points:

```json
{"point":{"slot":42,"blockHash":"<block-hash-hex>"},"results":[{"utxos_at":[{"txin":"<txid>#<ix>","txout":"<cbor-hex>"}]},{"utxos_with_asset":[{"txin":"<txid>#<ix>","txout":"<cbor-hex>","quantity":"3","created":{"slot":40,"blockHash":"<creation-hash-hex>"},"datum":{"kind":"none"}}]},{"utxos_at":[{"txin":"<txid>#<ix>","txout":"<cbor-hex>"}]}]}
```

Examples use placeholders, not literal valid address/hash/CBOR fixtures.
Results correlate by array position and query key. Preserve query order and
duplicates, with exactly one result per query; do not deduplicate or merge.
Each member list is ascending by `TxIn` (txid bytes, then numeric output index).
Address members retain legacy `txin`/`txout` encoding. Asset members retain
legacy `txin`, `txout`, decimal-string `quantity`, `created` and `datum`
(`none`, `hash` with `hash`, or `inline` with `cbor`) encoding. `created` is the
output's original creation point, which can precede the batch's indexed point.
Stored output bytes are returned unchanged as lower-case base16.

## Input and parser rules

- Append the new alternative after the four existing parser alternatives:
  `utxos_at`, `ready`, `await`, `utxos_with_asset`, then `read_view`.
  Preserve fallback after a failed legacy alternative. Even an invalid asset
  request already accepted as `InvalidAssetQuery` retains precedence.
- If no legacy parser accepts and `read_view` is present, validate the whole
  batch before storage access. Require an array with at least one element.
  A singleton is valid; mixed, address-only and asset-only batches are valid.
- Batch-only top-level objects have exactly `read_view`. Unknown top-level or
  element keys, zero/two query keys, wrong types or invalid entries refuse the
  whole batch. These restrictions never override an accepted legacy request.
- Address values use the existing raw-byte hex decoder, case-insensitive,
  including its acceptance of empty bytes; no new ledger-address validation.
- Assets reuse `parseAssetQuery`: exactly `policy_id` and `asset_name`, both
  even-length valid hex in either case; policy is 28 bytes, name 0–32 bytes.
  Missing, additional or wrongly typed fields refuse the batch.
- Invalid batch input produces `{"error":"invalid_read_view","detail":"<text>"}`,
  without point/results or partial execution. Detail identifies the first
  invalid element by zero-based position where applicable; prose is diagnostic.
  Invalid JSON or a line without an accepted request key still receives
  `{"error":"malformed json"}`.

## Availability and snapshot requirements

After validation call `IndexerHandle.readView` once with all queries. Use only
its materialized `ivPoint` and `ivResults` to form the response; never compose
legacy reads, singleton view reads, a later point probe or readiness-derived
point. Availability, contents and point belong to that one storage snapshot.

Forward #200 refusal shape without point, results or disclosure fields:

```json
{"error":"asset_index_unavailable","reason":"no_indexed_point"}
```

| Library refusal | Wire `reason` |
|---|---|
| `NoIndexedPoint` | `no_indexed_point` |
| `AssetIndexAbsent` (including degraded/incomplete) | `absent` |
| `AssetIndexRebuilding` | `rebuilding` |
| `AssetIndexInconsistent _` | `inconsistent` |

Preserve library reason precedence: rebuilding/absent can precede no point.
An asset match whose output cannot decode for datum encoding also refuses the
whole response as `inconsistent`; never fabricate datum or return earlier rows.
Address-only batches inherit `readView` availability checks. Legacy
`snapshotAt`/`utxos_at` remains independently usable on degraded stores.
An empty member list succeeds only at an available indexed snapshot with no
matches. No indexed point is fabricated, and empty results are not refusals.

## Declared invariants and proposed enforcement

All enforcement below is PLANNED, unexecuted in this docs-only phase.
BLOCKING severity reflects consumer transaction decisions; no blocking residual.

| Name | Severity | Observable truth / planned proof |
|---|---|---|
| one-snapshot-per-socket-batch | BLOCKING | Every answer equals independent state at one point; socket split-snapshot fault KILLED. |
| socket-point-binds-all-contents | BLOCKING | Slot and hash are the view's point; every member, bytes, quantity and creation datum agree with its model state. |
| unavailable-view-refuses-entire-batch | BLOCKING | All four reasons, mixed and address-only refusal, no partial/empty fallback; available no-match control succeeds. |
| legacy-request-response-bytes-preserved | BLOCKING | Baseline/candidate socket byte comparison covers all four endpoints and ambiguous parser precedence. |
| ordered-complete-validated-batch | BLOCKING | Exact query/result cardinality, order, duplicates and input validation before reads; invalid-member controls. |
| docs-describe-actual-socket-contract | ADVISORY | Required request/response/point/refusal examples checked against socket cases; source review. |

## Acceptance boundaries

`plan.md` specifies the executing socket witness and `gates.md` its CI wiring.
Separately stamped answers, source inspection, compilation, setup errors and
skips do not establish atomicity. Proof uses ledger-reachable state transitions:
a txid commits to outputs; a move spends an old TxIn and creates a new one.
No requested point P, timeout for point acquisition, coverage/freshness fields,
persistence, preprod or Singular acceptance is included. Socket evidence proves
the daemon interface locally; live-chain and consumer acceptance remain separate.
