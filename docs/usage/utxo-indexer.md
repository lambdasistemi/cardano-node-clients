# utxo-indexer

In-process address→UTxO indexer daemon. Follows the chain via
Node-to-Client (N2C) ChainSync from a single Cardano relay, maintains
an indexed view (in-memory or RocksDB-backed), and exposes three read
primitives over a Unix-domain NDJSON socket: `ready`,
`utxos_at <addr>`, and `await <txin> [timeout_seconds]`.

## CLI

```bash
utxo-indexer \
  --relay-socket   /path/to/cardano-node/node.sock \
  --listen         /tmp/idx.sock \
  --network-magic  42 \
  --byron-epoch-slots 86400 \
  [--ready-threshold-slots 60] \
  [--security-param-k 2160] \
  [--db-path        /tmp/idx-db] \
  [--reconnect-initial-ms          1000] \
  [--reconnect-max-ms              30000] \
  [--reconnect-reset-threshold-ms  30000] \
  [--node-ready-timeout-ms         <ms>]
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--relay-socket` | — | Unix socket of the upstream cardano-node relay. |
| `--listen` | — | Path the indexer will bind for NDJSON consumers. |
| `--network-magic` | — | Cardano network magic (mainnet=764824073, preprod=1, preview=2, antithesis testnet=42). |
| `--byron-epoch-slots` | — | Byron-era epoch length (mainnet=21600, antithesis testnet=86400). |
| `--ready-threshold-slots` | `60` | `slotsBehind ≤ this ⇒ ready=true`. |
| `--security-param-k` | `2160` | Cardano security parameter k; caps the rollback log. |
| `--db-path` | (in-memory) | If set, RocksDB at this path. State survives process restart. |
| `--reconnect-initial-ms` | `1000` | Base of the supervisor's full-jitter exponential backoff. |
| `--reconnect-max-ms` | `30000` | Cap of the supervisor's backoff window. |
| `--reconnect-reset-threshold-ms` | `30000` | Healthy-run duration that resets the supervisor's failure counter. |
| `--node-ready-timeout-ms` | unset | Total cap on the LSQ tip probe. **Unset = wait forever** for the upstream node's ChainDB to load. Set explicitly for CI scenarios that want to fail fast. |

All flags are parsed in `app/utxo-indexer/Main.hs`; required flags are
`--relay-socket`, `--listen`, `--network-magic`, and
`--byron-epoch-slots`.

## Read wire (NDJSON)

One request line per connection, one response line, then EOF:

```
REQ:  {"ready": null}
RESP: {"ready":<bool>, "tipSlot":<int|null>,
       "processedSlot":<int|null>, "slotsBehind":<int|null>, ...}

REQ:  {"utxos_at": "<hex-of-address-bytes>"}
RESP: {"utxos": [{"txin":"<txid>#<ix>", "txout":"<base16-cbor>"}, ...]}

REQ:  {"await": "<txid_hex>#<ix>"}            # optional trailing timeout
```

Address bytes go on the wire as hex; bech32 parsing lives in the
consumer. On upstream disconnect the `ready` response carries an
`upstream` object naming the reason, attempt counter, and
elapsed-since-disconnect time, while `utxos_at` and `await` continue
to be served from cached state.

## Reconnect behaviour (issue #97)

The daemon survives upstream relay disconnects (e.g. relay container
restart) without exiting:

- the listen socket keeps accepting consumer connections;
- `ready` returns `ready=false` with the `upstream` reason while
  disconnected;
- `utxos_at` and `await` keep serving cached state — consumer
  connections are never EOFed because of an upstream disconnect;
- before each reconnect attempt the supervisor probes the relay via
  LocalStateQuery (acquire volatile tip + read tip); ChainSync is
  attached only once the probe sees a non-Origin tip;
- reconnect retries use full-jitter exponential backoff (defaults
  1 s → 30 s) via `Control.Retry`.

Operators no longer need orchestrator-level `restart: always` on the
indexer container to recover from peer flapping.

## Stderr trace stream

Every lifecycle transition emits one line on stderr:

```
2026-04-30T12:34:56.789Z INFO indexer event=started        socketPath=... dbPath=...
2026-04-30T12:35:42.103Z INFO indexer event=disconnected   reason=bearer-closed
2026-04-30T12:35:42.380Z INFO indexer event=node-replaying attempt=1 elapsedMs=275
2026-04-30T12:35:43.500Z INFO indexer event=reconnecting   attempt=1 waitMs=312
2026-04-30T12:35:44.815Z INFO indexer event=reconnected    resumeSlot=12345 elapsedMs=2712
2026-04-30T12:40:00.001Z INFO indexer event=stopped        reason=normal
```

`grep '^.*indexer '` is the operator-friendly filter. Counting
`event=disconnected` vs `event=reconnected` per peer-restart cycle is
the recommended fault-injection assertion; `event=node-replaying`
lines reveal that the upstream relay is alive but its ChainDB hasn't
finished loading.

## Embedded use

Embedders that want to route `N2CEvent`s into their own tracer can
pass a custom `Tracer IO N2CEvent` to
`Cardano.Node.Client.UTxOIndexer.Daemon.runDaemon`'s first argument
instead of `defaultStderrTracer`. To own the `IndexerHandle` (RocksDB
is single-writer) and run the follower without the NDJSON server, use
`Cardano.Node.Client.UTxOIndexer.Follower.withChainSyncFollower`. The
`cardano-tx-generator` daemon in
[lambdasistemi/cardano-tx-tools](https://github.com/lambdasistemi/cardano-tx-tools)
embeds the indexer this way.
