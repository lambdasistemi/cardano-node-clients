# cardano-tx-generator

Long-running Cardano transaction-generator daemon designed to be driven
by the [Antithesis](https://antithesis.com/) test composer rather than
a clock. Creates monotonic UTxO and address pressure on a node by
submitting fan-out transactions to a growing population of
deterministically-derived addresses.

Replaces the Python `tx_generator.py` whose
[per-submission `cardano-cli query utxo --address`](https://github.com/cardano-foundation/cardano-node-antithesis/issues/69)
saturated the relay's local-state-query channel.

## Design

- One physical N2C connection to the relay carrying ChainSync (feeding
  an embedded address-to-UTxO indexer), LSQ (one-shot PParams query at
  startup, plus rare faucet UTxO selection), and LTxS (transaction
  submission). The shared mux session lands via `runNodeClientFull`
  ([#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)).
- Embedded
  [`utxo-indexer-lib`](https://github.com/lambdasistemi/cardano-node-clients/tree/main/lib-utxo-indexer)
  for fast address-keyed UTxO lookups on the hot transact path.
- [TxBuild DSL](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs)
  for transaction building; `BalanceResult` for fee + change.
- NDJSON-over-Unix-socket control wire matching the indexer's idiom —
  see
  [contracts/control-wire.md](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/contracts/control-wire.md).
- Per-request determinism: every `transact` / `refill` derives all
  randomness from the request's `seed` field. No `IO` RNG, no clock,
  no `/dev/urandom` on the tx path.

## CLI

```
cardano-tx-generator
  --relay-socket FILE          # devnet's N2C Unix socket
  --control-socket FILE        # the daemon will create this socket
  --state-dir DIR              # holds master.seed + next-hd-index
  --master-seed-file FILE      # 32 bytes; created on first run if absent
  --network-magic NAT          # devnet default: 42
  --byron-epoch-slots NAT      # default: 432000
  --faucet-skey-file FILE      # 32-byte raw signing key
  --await-timeout-seconds NAT  # default: 30
  --ready-threshold-slots NAT  # default: 10
  --security-param-k NAT       # default: 2160
  [--db-path DIR]              # if set, indexer uses RocksDB; else in-memory
```

## Wire summary (full schemas in
[`contracts/control-wire.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/contracts/control-wire.md))

```
{"transact": {"seed": <u64>, "fanout": <u8>, "prob_fresh": <0..1>}}
  → {"ok": true, "txId": ..., "src": ..., "dsts": [...],
                 "values_lovelace": [...], "fresh_count": ...,
                 "awaited": ...}
  | {"ok": false, "reason": "no-pickable-source" | "index-not-ready"
                          | "submit-rejected: <ledger>"}

{"refill": {"seed": <u64>}}
  → {"ok": true, "txId": ..., "fresh_index": ...,
                 "value_lovelace": ..., "awaited": ...}
  | {"ok": false, "reason": "faucet-not-known" | "faucet-exhausted"
                          | "submit-rejected: <ledger>"}

{"snapshot": null}
  → {"populationSize": ..., "p10_lovelace": ..., "p50_lovelace": ...,
     "p90_lovelace": ..., "tipSlot": ..., "lastTxId": ...}

{"ready": null}
  → {"ready": ..., "indexReady": ..., "faucetUtxosKnown": ...}
```

## Driving consumer

The
[Antithesis testnet](https://github.com/cardano-foundation/cardano-node-antithesis)
[adopts this daemon](https://github.com/cardano-foundation/cardano-node-antithesis/issues/78)
in place of the Python `tx_generator.py`. Composer scripts speak the
NDJSON wire above via `nc -U`.

## Specification

The full speckit artifacts are at
[`specs/034-cardano-tx-generator/`](https://github.com/lambdasistemi/cardano-node-clients/tree/main/specs/034-cardano-tx-generator):

- [`spec.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/spec.md) — user stories + functional requirements + success criteria.
- [`plan.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/plan.md) — technical plan.
- [`research.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/research.md) — Phase 0 archaeology decisions D1–D10.
- [`data-model.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/data-model.md) — entity shapes.
- [`contracts/control-wire.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/contracts/control-wire.md) — wire schemas.
- [`quickstart.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/quickstart.md) — operator bring-up.
- [`tasks.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/034-cardano-tx-generator/tasks.md) — vertical-commit task breakdown.

## See also

- [`#84`](https://github.com/lambdasistemi/cardano-node-clients/issues/84) — driving issue.
- [`#79`](https://github.com/lambdasistemi/cardano-node-clients/pull/79) — upstream address-to-UTxO indexer.
- [`#95`](https://github.com/lambdasistemi/cardano-node-clients/issues/95) — combined N2C helper.
