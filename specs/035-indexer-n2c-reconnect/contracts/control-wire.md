# Contract: utxo-indexer control wire (with disconnect-aware semantics)

**Feature**: 035-indexer-n2c-reconnect
**Date**: 2026-04-29 (revised 2026-04-30)

This document specifies the additive changes to the utxo-indexer's Unix-socket NDJSON protocol introduced by feature 035. The wire shape is **backwards-compatible**: existing consumers that ignore unknown fields continue to work without changes.

## Endpoint

Single Unix-domain socket at the path passed to `--listen`. One request → one response → connection close. Requests are JSON objects, responses are JSON objects. NDJSON framing.

## Requests

Unchanged. The supported requests are still `{"ready": null}`, `{"utxos_at": "<address>"}`, and `{"await": {"tx_in": "<hash>#<ix>", "timeout_ms": <int|null>}}`.

## Responses

### `ready` — extended

Unchanged fields:

| Field | Type | Meaning |
|-------|------|---------|
| `ready` | `bool` | True ⇔ chain-sync is connected **and** `slotsBehind ≤ ready_threshold_slots`. |
| `tipSlot` | `int \| null` | Tip slot last observed from the upstream peer. Null before first roll-forward. |
| `processedSlot` | `int \| null` | Slot of the most recently applied block. |
| `slotsBehind` | `int \| null` | `tipSlot - processedSlot` (clamped to ≥ 0). |

New optional field:

| Field | Type | Meaning |
|-------|------|---------|
| `upstream` | `object \| omitted` | Present **only** while the supervisor is in its reconnect loop; omitted while connected. |

`upstream` schema:

```json
{
  "status":     "disconnected",
  "reason":     "<short description, e.g. 'bearer-closed'>",
  "attempt":    3,
  "elapsedMs":  4200
}
```

- `status`: always `"disconnected"` for now (only constructor of `UpstreamDisconnected`). Reserved for future expansion (e.g. `"connecting"` if we add a separate handshake state).
- `reason`: short, human-readable reason. Derived from `displayException` truncated to ~80 chars. Stable enough for log greps; not a machine-parseable code.
- `attempt`: 1-based counter of reconnect attempts since the most recent successful chain-sync run (or since process start if never connected).
- `elapsedMs`: milliseconds since the disconnect was first observed.

**Semantics during disconnect**:

- `ready = false` is **forced** while `upstream` is present. Even if the cached `tipSlot`/`processedSlot`/`slotsBehind` would otherwise satisfy the threshold, the indexer reports not-ready.
- `tipSlot` and `processedSlot` reflect the last values observed before disconnect; they do not advance.

### `utxos_at <addr>` — unchanged shape, clarified semantics

Returns the persisted UTxO set at the most recently applied block.

- **While connected**: result reflects the chain state at `processedSlot` (current behaviour).
- **While disconnected**: result reflects the chain state at the last `processedSlot` *before* disconnect. The response is **not** held back waiting for reconnect, and the connection is **not** closed (FR-006). Consumers should treat the result as potentially stale and check the most recent `ready` response if freshness matters.

### `await tx_in [timeout_ms]` — unchanged shape, clarified semantics

Blocks until either the named `tx_in` appears in the indexer's UTxO set, or `timeout_ms` elapses.

- **While connected**: current behaviour.
- **While disconnected**: the blocking call **continues to block** (it does not error out, does not close the connection). New blocks will not appear during the disconnect, so a successful return implies the upstream returned and at least one block containing the tx was applied. The `timeout_ms` clock keeps running through the disconnect window — if the timeout elapses before reconnect, the response is the existing timeout response.

## Examples

### Connected, synced

```json
> {"ready": null}
< {"ready": true, "tipSlot": 12345, "processedSlot": 12345, "slotsBehind": 0}
```

### Disconnected, attempt 3, 4.2 s in

```json
> {"ready": null}
< {"ready": false, "tipSlot": 12340, "processedSlot": 12340, "slotsBehind": 0,
   "upstream": {"status": "disconnected", "reason": "bearer-closed",
                "attempt": 3, "elapsedMs": 4200}}
```

### Disconnected, query still answered from cache

```json
> {"utxos_at": "addr_test1..."}
< {"utxos": [{"txIn": "...#0", "value": {"lovelace": 1000000}, "datum": null}]}
```

(No `upstream` field on `utxos` responses; that signal is on `ready` only.)

## Backwards-compatibility rules

- New `upstream` field is **additive**. Pre-035 consumers ignore it.
- All previous responses to all previous requests are unchanged in the connected path.
- When disconnected, the only behavioural changes are: (a) `ready=false` even when caches would say otherwise; (b) the new `upstream` object appears on `ready` responses; (c) the listen socket *never* EOFs because of upstream disconnect.

## Out of scope

- A `disconnected` *event* push channel. The current model is request/response per connection; consumers that want real-time disconnect notifications must poll `ready` (or migrate to a future streaming endpoint, not part of this feature).
- Multi-peer status. The indexer is single-peer (spec assumption).
