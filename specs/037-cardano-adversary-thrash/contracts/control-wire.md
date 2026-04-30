# Control Wire — `chain_sync_thrash` endpoint

Extends the cardano-adversary daemon's NDJSON control wire (defined
in [`../../036-cardano-adversary/contracts/control-wire.md`][036])
with one additional endpoint. Same framing rules apply: one JSON
object per line, single request → single response → EOF + close.

## `chain_sync_thrash` — single connection, repeated `MsgFindIntersect`

**Request**:
```json
{"chain_sync_thrash": {"seed": 12345678901234567890,
                       "intersect_count": 50,
                       "settle_ms": 50}}
```

| Field | Type | Meaning |
|---|---|---|
| `seed` | `uint64` | Sole source of randomness. Drives the per-request `StdGen` via `splitFromSeed`, which then chooses the producer and samples each successive intersect point. |
| `intersect_count` | `uint16` (clamped to `[1, 1000]`) | How many `MsgFindIntersect` messages to issue on the single chain-sync connection. |
| `settle_ms` | `uint16` (clamped to `[0, 60000]`) | Additional sleep between issues (on top of the protocol's natural RTT). |

**Response (success)**:
```json
{"ok": true,
 "details": {
   "peerName": "p2.example",
   "intersectsIssued": 50,
   "intersectCountClamped": false,
   "settleMsClamped": false
 }}
```

`intersectCountClamped` / `settleMsClamped` are `true` iff the
incoming value was outside the documented range and the daemon
clamped it. The actual value used is `intersectsIssued` (mirrors
the request's `intersect_count` after clamping).

**Response (structured failure)**:
```json
{"ok": false, "reason": "no-chain-points-file"}
{"ok": false, "reason": "no-chain-points-yet"}
{"ok": false, "reason": "no-producers"}
{"ok": false, "reason": "connection-refused"}
```

| `reason` | When |
|---|---|
| `no-chain-points-file` | Daemon was started without `--chain-points-file`, or the configured path does not exist on disk. |
| `no-chain-points-yet` | File exists but contains no parseable lines (typical at start-of-test). |
| `no-producers` | Daemon was started without any `--producer-host` flag. |
| `connection-refused` | DNS resolution failed or the TCP connect was refused / RST. The daemon does not retry — the composer driver retries by firing the next tick. |

## Composer driver SDK assertion mapping

| `reason` | exit | Antithesis SDK assertion |
|---|---|---|
| (none — `ok == true`) | 0 | `sdk_sometimes true "adversary_chain_sync_thrash_completed"` |
| `no-chain-points-file` | 1 | `sdk_unreachable "adversary_misconfigured_no_points_file"` |
| `no-chain-points-yet` | 1 | `sdk_sometimes false "adversary_no_chain_points"` |
| `no-producers` | 1 | `sdk_unreachable "adversary_misconfigured_no_producers"` |
| `connection-refused` | 1 | `sdk_sometimes false "adversary_thrash_connection_refused"` (expected occasionally under fault injection) |

## Framing rules

Inherited from [`036-cardano-adversary/contracts/control-wire.md`][036]:
one request per connection, response is one line + `\n`, malformed
JSON → `{"error": "malformed json"}`, unknown top-level key →
`{"error": "unknown request"}`. No streaming.

[036]: ../../036-cardano-adversary/contracts/control-wire.md
