# cardano-adversary

N2N adversary daemon for fault-injection testing (for example under
Antithesis). It listens on a Unix-domain control socket and answers one
NDJSON request per connection, driving adversarial Node-to-Node
ChainSync connections against configured block producers.

## CLI

```bash
cardano-adversary \
  --control-socket PATH \
  --network-magic  INT \
  [--producer-host HOST]... \
  [--producer-port INT] \
  [--chain-points-file PATH]
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--control-socket` | — | Bind path for the NDJSON control socket. Required. |
| `--network-magic` | — | Cardano network magic for the N2N handshake. Required. |
| `--producer-host` | (none) | Producer hostname the `chain_sync_flap` endpoint targets. Repeatable. |
| `--producer-port` | `3001` | N2N port for `chain_sync_flap`. |
| `--chain-points-file` | (unset) | File of chain points written by `tracer-sidecar`; re-read on every `chain_sync_flap` request. |

`cardano-adversary --help` prints the same summary. The daemon installs
a `SIGTERM` handler, unlinks the socket on shutdown, and exits cleanly.

## Control wire (NDJSON)

One request line per connection, one response line, then EOF. The full
schema is the contract at
`specs/036-cardano-adversary/contracts/control-wire.md`.

### `ready`

```
REQ:  {"ready": null}
RESP: {"ready": <bool>,
       "details": {"n2nHandshakeOk": <bool>,
                   "configuredHosts": [<host>, ...]}}
```

`configuredHosts` echoes the `--producer-host` values.

### `chain_sync_flap`

Opens `n_conns` concurrent adversarial ChainSync connections against
the configured producers, each starting from a randomised chain point
sampled (seeded by `seed`) from the chain-points file and pulling at
most `limit` blocks before disconnecting.

```
REQ:  {"chain_sync_flap": {"seed": <u64>, "limit": <u32>, "n_conns": <u16>}}
RESP: {"ok": true,
       "details": {"connections": <int>,
                   "peerNames": [<host>, ...],
                   "limit": <u32>}}
```

Structured failures keep `ok: false` with a `reason`:

| `reason` | Cause |
|----------|-------|
| `no-producers` | No `--producer-host` was configured. |
| `no-chain-points-file` | The `--chain-points-file` is unset or missing on disk. |
| `no-chain-points-yet` | The file exists but holds no usable chain points yet. |

Wire-level problems return `{"error": "<reason>"}` (for example
malformed JSON or an unknown top-level key).

## Random source

Every adversarial decision draws from
`Cardano.Node.Client.Adversary.RandomSource`. The default
implementation shells out to the `antithesis_random` CLI when it is on
`PATH` (so the Antithesis hypervisor can bias choices) and falls back
to `System.Random` for local development when it is not. The per-request
`seed` field is turned into a `StdGen` so a request is reproducible
from its seed.
