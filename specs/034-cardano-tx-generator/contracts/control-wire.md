# Control Wire — NDJSON over Unix `SOCK_STREAM`

Same idiom as the indexer's
[`UTxOIndexer.Server`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/UTxOIndexer/Server.hs):
one JSON object per line, single request → single response → EOF
+ close. UTF-8. Unknown top-level keys are rejected with `{"error":
"unknown request"}`.

The daemon listens on `--control-socket`. Filesystem permissions
on the socket are the only authentication.

## `transact` — submit one fan-out transaction

**Request**:
```json
{"transact": {"seed": 12345678901234567890,
              "fanout": 6,
              "prob_fresh": 0.5}}
```

- `seed` — `uint64`, sole source of randomness for this request.
- `fanout` — `uint8` ≥ 2, K outputs to fan into.
- `prob_fresh` — `float` ∈ [0.0, 1.0], P(destination_i is freshly
  derived).

**Response (success)**:
```json
{"ok": true,
 "txId": "<64-hex>",
 "src": 17,
 "dsts": [42, 43, 9, 11, 44, 18],
 "values_lovelace": [2000000, 1850000, 2100000, 1950000, 2050000, 1900000],
 "fresh_count": 3,
 "awaited": true}
```

**Response (not applicable / error)**:
```json
{"ok": false, "reason": "no-pickable-source"}
{"ok": false, "reason": "index-not-ready"}
{"ok": false, "reason": "faucet-exhausted"}
{"ok": false, "reason": "submit-rejected: <ledger error text>"}
```

The composer driver script maps:

| `reason` | `exit` | Antithesis SDK assertion |
|---|---|---|
| (none — `ok == true`) | 0 | `sdk_sometimes true "tx_generator_landed"` |
| `no-pickable-source` | 1 | `sdk_sometimes false "tx_generator_starved"` |
| `index-not-ready` | 1 | `sdk_sometimes false "tx_generator_index_starting"` |
| `faucet-exhausted` | 1 | `sdk_sometimes false "tx_generator_faucet_dry"` |
| `submit-rejected: …` | 1 | `sdk_unreachable "tx_generator_submit_rejected"` (with reason in `details`) |

## `refill` — pull faucet → fresh population address

**Request**:
```json
{"refill": {"seed": 9876543210987654321}}
```

**Response (success)**:
```json
{"ok": true,
 "txId": "<64-hex>",
 "fresh_index": 18,
 "value_lovelace": 50000000000,
 "awaited": true}
```

**Response (failure)**:
```json
{"ok": false, "reason": "faucet-not-known"}
{"ok": false, "reason": "faucet-exhausted"}
{"ok": false, "reason": "submit-rejected: <ledger error text>"}
```

## `snapshot` — read-only validator query

**Request**:
```json
{"snapshot": null}
```

**Response**:
```json
{"populationSize": 137,
 "p10_lovelace": 1850000,
 "p50_lovelace": 2050000,
 "p90_lovelace": 49850000000,
 "tipSlot": 14502,
 "lastTxId": "<64-hex|null>"}
```

`populationSize` is `nextHDIndex`. `p*_lovelace` are coin
percentiles over the union of UTxO values at all population
addresses. If `populationSize == 0`, percentiles are reported as
`null`. `tipSlot` is `null` until the embedded index has observed
its first block.

## `ready` — readiness probe

**Request**:
```json
{"ready": null}
```

**Response**:
```json
{"ready": true, "indexReady": true, "faucetUtxosKnown": true}
```

`ready = indexReady && faucetUtxosKnown`. Shape mirrors the
indexer's
[`ReadyStatus`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/UTxOIndexer/Server.hs#L94-L109)
where it overlaps.

## Framing details

- One request per connection. After the response is written, the
  daemon closes; no keep-alive.
- Request line is read up to and including the first `\n`. Trailing
  bytes after `\n` (if any) are discarded.
- Response is one line followed by `\n`, then EOF.
- No streaming responses in v1. (`transact` blocks until the
  `await` resolves or times out, then writes its single response.)
- Concurrency: many concurrent `snapshot` and `ready` connections
  are fine. `transact` and `refill` requests are serialised by
  `daemonNextHDIndex` — at most one is in flight at a time (FR-016).
- Malformed JSON: `{"error": "malformed json"}`, then close.
- Unknown top-level key: `{"error": "unknown request"}`, then close.
