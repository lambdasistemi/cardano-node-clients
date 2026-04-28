# Quickstart — cardano-tx-generator

Bring up a single daemon against a local devnet, fire a few
trigger requests, and read a snapshot. End-to-end against the
in-tree devnet harness.

## Prerequisites

- A devnet bring-up via the existing
  [`Cardano.Node.Client.E2E.Setup.withDevnet`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/e2e-test/Cardano/Node/Client/E2E/Setup.hs)
  pattern, or `nix run .#devnet`.
- A faucet signing key + address on that devnet (the genesis
  utxo holder is the natural fit; existing E2E tests already
  derive one).
- A scratch directory for daemon state (`--state-dir`).

## CLI

```
cardano-tx-generator
  --relay-socket FILE          # devnet's N2C Unix socket
  --control-socket FILE        # the daemon will create this socket
  --state-dir DIR              # holds master.seed + next-hd-index
  --master-seed-file FILE      # 32 bytes; created on first run if absent
  --network-magic NAT          # devnet default: 42
  --byron-epoch-slots NAT      # default: 432000
  --faucet-skey-file FILE      # genesis-derived signing key
  --await-timeout-seconds NAT  # default: 30
  --ready-threshold-slots NAT  # default: 10  (forwarded to embedded index)
  --security-param-k NAT       # default: 2160 (forwarded to embedded index)
  [--db-path DIR]              # if set, indexer uses RocksDB; else in-memory
```

No `--rate`, no `--fanout`, no `--prob-fresh`. Those are per-request
fields on the control wire.

## Bring-up

```bash
mkdir -p /tmp/txgen-state
head -c 32 /dev/urandom > /tmp/txgen-state/master.seed
cardano-tx-generator \
  --relay-socket "$DEVNET_SOCKET" \
  --control-socket /tmp/txgen.sock \
  --state-dir /tmp/txgen-state \
  --master-seed-file /tmp/txgen-state/master.seed \
  --network-magic 42 \
  --faucet-skey-file /tmp/devnet/genesis-faucet.skey &
```

The daemon opens **one** N2C connection to `$DEVNET_SOCKET`
multiplexing ChainSync + LSQ + LTxS (per
[#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)),
queries protocol parameters once, starts the embedded index from
genesis (or resumes if `--db-path` is set), and binds the control
socket.

## Drive it

```bash
# Wait for ready
until echo '{"ready":null}' | nc -U /tmp/txgen.sock | grep -q '"ready":true'; do
  sleep 1
done

# Bootstrap: pull from faucet to a fresh population address
echo '{"refill":{"seed":1}}' | nc -U /tmp/txgen.sock

# Submit 100 fan-out transactions with distinct seeds
for s in $(seq 2 101); do
  echo "{\"transact\":{\"seed\":$s,\"fanout\":6,\"prob_fresh\":0.5}}" \
    | nc -U /tmp/txgen.sock
done

# Read the resulting pressure curve
echo '{"snapshot":null}' | nc -U /tmp/txgen.sock
```

Expected end state (per SC-001):

- 1 refill + 100 transacts → `populationSize` ≈ 1 + 100 · 6 · 0.5
  ≈ 301 (variance per the seed sequence).
- `p50_lovelace` strictly below the post-refill UTxO value (per
  SC-005).
- `lastTxId` is the txId of the final `transact` response.

## Replay determinism (SC-002)

Wipe the state dir, restore `master.seed` from a known value,
run the same seed sequence — the txIds emitted in responses are
byte-for-byte identical to the previous run.

```bash
rm -rf /tmp/txgen-state
mkdir -p /tmp/txgen-state
cp /known/master.seed /tmp/txgen-state/master.seed
# ... same bring-up + same seed sequence ...
```

## Restart resilience (SC-006)

Send 50 transacts, send `SIGTERM` to the daemon, wait, restart
with the same flags. The 51st transact (with the next-in-sequence
seed) lands as if no restart happened: same source pick (the
state dir survives), same destinations (the seed is the only
randomness on the tx path), same change `TxIn` await.

## Antithesis composer wiring (downstream, separate repo)

The [#78](https://github.com/cardano-foundation/cardano-node-antithesis/issues/78)
adoption issue covers the composer side: `helper_sdk_lib.sh`
reused verbatim from
[asteria-player](https://github.com/cardano-foundation/cardano-node-antithesis/tree/main/components/asteria-player/composer/asteria),
plus four short scripts under
`components/tx-generator/composer/tx-generator/` —
`parallel_driver_transact.sh`, `parallel_driver_refill.sh`,
`eventually_population_grew.sh`, `finally_pressure_summary.sh`.
Wire format above is what those scripts speak via `nc -U`.

## What "good" looks like

Three observations from outside the daemon are the contract:

1. `snapshot.populationSize` strictly grows across the run
   (modulo restart and rollback noise).
2. `snapshot.p50_lovelace` strictly drops over a sustained run.
3. `cardano-cli query utxo --address <addr_i>` agrees with the
   daemon's computed view at every population address (inherited
   from the indexer library's contract).
