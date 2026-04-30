# Control Wire — NDJSON over Unix `SOCK_STREAM`

Same idiom as
[`UTxOIndexer.Server`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/UTxOIndexer/Server.hs)
and the [tx-generator wire
spec](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/contracts/control-wire.md):
one JSON object per line, single request → single response → EOF
+ close. UTF-8. Unknown top-level keys are rejected with `{"error":
"unknown request"}`.

The daemon listens on `--control-socket`. Filesystem permissions
on the socket are the only authentication.

## `ready` — readiness probe

**Request**:
```json
{"ready": null}
```

**Response**:
```json
{"ready": true,
 "details": {
   "n2nHandshakeOk": true,
   "configuredHosts": ["p1.example", "p2.example", "p3.example"]
 }}
```

Or, before warmup:
```json
{"ready": false,
 "details": {
   "n2nHandshakeOk": false,
   "configuredHosts": ["p1.example", "p2.example", "p3.example"]
 }}
```

`ready` is the AND of all readiness components surfaced under
`details`. Composer drivers should treat `ready: false` as "skip
this tick" rather than "fail this tick".

## `chain_sync_flap` — implemented in PR C

**Request**:
```json
{"chain_sync_flap": {"seed": 12345678901234567890,
                     "limit": 100,
                     "n_conns": 1}}
```

- `seed` — `uint64`, sole source of randomness for this request.
  Used to derive the per-request `StdGen` via `splitFromSeed`,
  which then samples a starting point per connection from the
  parsed chain-points file.
- `limit` — `uint32`, maximum blocks pulled per connection before
  the adversary disconnects (mirror of the original one-shot
  binary's `LIMIT` env var).
- `n_conns` — `uint16`, number of concurrent N2N connections
  spawned by this single request.

**Response (success)**:
```json
{"ok": true,
 "details": {
   "connections": 1,
   "peerNames": ["p1.example", "p2.example", "p3.example"],
   "limit": 100
 }}
```

The success body is intentionally coarse: every connection the
daemon dispatched is reflected in `connections`, but
per-connection outcome (blocks pulled, intersection point chosen,
DNS or handshake error) is not yet streamed back. Adding a richer
`details` shape is additive and does not break existing consumers
— they will see new fields and ignore them.

**Response (structured failure)**:
```json
{"ok": false, "reason": "no-chain-points-file"}
{"ok": false, "reason": "no-chain-points-yet"}
{"ok": false, "reason": "no-producers"}
```

| `reason` | When |
|---|---|
| `no-chain-points-file` | The daemon was started without `--chain-points-file`, or the configured path does not exist on disk. |
| `no-chain-points-yet` | The file exists but contains no parseable lines (typical at start-of-test, before `tracer-sidecar` has emitted any points). |
| `no-producers` | The daemon was started without any `--producer-host` flag, so there is nothing to fan connections across. |

The composer driver script in
`cardano-foundation/cardano-node-antithesis` should map outcomes to
SDK assertions:

| `reason` | `exit` | Antithesis SDK assertion |
|---|---|---|
| (none — `ok == true`) | 0 | `sdk_sometimes true "adversary_chain_sync_flap_completed"` |
| `not-implemented` | 1 | `sdk_unreachable "adversary_endpoint_not_implemented"` (only seen during a PR-B → PR-C transition window; should never appear after this PR merges) |
| `no-chain-points-file` | 1 | `sdk_unreachable "adversary_misconfigured_no_points_file"` |
| `no-chain-points-yet` | 1 | `sdk_sometimes false "adversary_no_chain_points"` |
| `no-producers` | 1 | `sdk_unreachable "adversary_misconfigured_no_producers"` |

## Framing details

- One request per connection. After the response is written, the
  daemon closes; no keep-alive.
- Request line is read up to and including the first `\n`. Trailing
  bytes after `\n` (if any) are discarded.
- Response is one line followed by `\n`, then EOF.
- Concurrency: many concurrent `ready` connections are fine.
  Misbehaviour endpoints (when implemented) MAY be serialised by
  the daemon if the underlying mini-protocol state is shared; the
  serialisation policy SHALL be documented per endpoint.
- Malformed JSON: `{"error": "malformed json"}`, then close.
- Unknown top-level key: `{"error": "unknown request"}`, then close.
- Reserved-but-not-implemented endpoint: `{"ok": false, "reason":
  "not-implemented"}`, then close. This is distinct from "unknown
  request" so composer drivers can tell "endpoint will exist later"
  from "this endpoint is a typo".
