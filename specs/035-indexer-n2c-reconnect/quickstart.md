# Quickstart: utxo-indexer auto-reconnect on N2C peer close

**Feature**: 035-indexer-n2c-reconnect
**Date**: 2026-04-30

## Reproduce the bug (against pre-fix code)

The regression test that demonstrates the bug is on `main` as of PR https://github.com/lambdasistemi/cardano-node-clients/pull/100 (`test/Cardano/Node/Client/E2E/Issue97ReproSpec.hs`):

```bash
nix develop -c cabal test e2e-tests -O0 \
  --test-show-details=direct \
  --test-options='--match "issue #97"'
```

Output against pre-fix code:

```
issue #97 — BearerClosed escape from runChainSyncN2C
  runChainSyncN2C terminates with a BearerClosed-like exception when the upstream relay restarts [✔]
```

The test asserts that `runChainSyncN2C` lets a `BearerClosed` exception escape its own catch path on relay restart — i.e. the bug is real.

## Run the new E2E (post-fix)

```bash
nix develop -c cabal test e2e-tests -O0 \
  --test-show-details=direct \
  --test-options='--match "reconnect supervisor"'
```

The spec at `test/Cardano/Node/Client/E2E/UTxOIndexerReconnectSpec.hs` covers all three user stories in one test:

1. The daemon's `Async` does not exit during the restart window (US1 / SC-001).
2. The listen socket continues to accept connections (US1 / SC-005).
3. `ready` returns an `upstream` object with `status="disconnected"` during the gap (US2 / FR-005).
4. `utxos_at` is answered from cached state during the gap (US2 / FR-006).
5. After the relay returns, `processedSlot` strictly advances past pre-restart value (FR-003 / SC-002).
6. The captured event stream contains the expected `IndexerStarted`/`IndexerDisconnected`/`IndexerReconnecting`/`IndexerReconnected` (US3 / SC-004).

## CLI surface (after the fix)

New optional flags on `utxo-indexer`:

| Flag | Default | Purpose |
|------|---------|---------|
| `--reconnect-initial-ms` | `1000` | Base of the supervisor's full-jitter exponential backoff. |
| `--reconnect-max-ms` | `30000` | Cap of the supervisor's full-jitter backoff. |
| `--reconnect-reset-threshold-ms` | `30000` | Chain-sync run duration that resets the supervisor's failure counter. |
| `--node-ready-timeout-ms` | unset | Per-attempt cap on the LSQ tip probe. **Unset = wait forever** for chain replay to complete. Operators who want a finite cap (e.g. for CI) can set this. |

All existing flags are unchanged.

## Reproducer (production failure mode)

This matches the reproducer in https://github.com/lambdasistemi/cardano-node-clients/issues/97 and is the steady-state regression we are removing.

```bash
INDEXER=$(nix build .#packages.x86_64-linux.utxo-indexer --print-out-paths --no-link)/bin/utxo-indexer

# 3-pool / 2-relay private testnet from cardano-foundation/cardano-node-antithesis
sudo "$INDEXER" \
  --relay-socket   /var/lib/docker/volumes/cardano_node_master_relay1-state/_data/node.socket \
  --listen         /tmp/idx.sock \
  --network-magic  42 \
  --byron-epoch-slots 86400 \
  --ready-threshold-slots 5 \
  --security-param-k 432 \
  --db-path        /tmp/idx-db &

# Confirm steady-state: ready=true, slotsBehind=0
echo '{"ready":null}' | sudo socat - UNIX-CONNECT:/tmp/idx.sock

# Restart the upstream relay
docker restart relay1
```

**Before the fix**: indexer exits with `bearer closed`; subsequent `ready` queries get EOF.
**After the fix**: indexer keeps running; `ready` includes `"upstream":{"status":"disconnected",...}` during the gap; the indexer reaches `ready=true` again once the relay returns, **without** re-indexing from genesis.

## Stderr trace stream

The executable wires `defaultStderrTracer` from `Cardano.Node.Client.N2C.Trace`. Every lifecycle transition emits a single line:

```
2026-04-30T12:34:56.789Z INFO indexer event=started        socketPath=... dbPath=...
2026-04-30T12:35:42.103Z INFO indexer event=disconnected   reason=bearer-closed
2026-04-30T12:35:42.380Z INFO indexer event=node-replaying attempt=1 elapsedMs=275
2026-04-30T12:35:42.880Z INFO indexer event=node-replaying attempt=2 elapsedMs=775
2026-04-30T12:35:43.500Z INFO indexer event=reconnecting   attempt=1 waitMs=312
2026-04-30T12:35:44.815Z INFO indexer event=reconnected    resumeSlot=12345 elapsedMs=2712
2026-04-30T12:40:00.001Z INFO indexer event=stopped        reason=normal
```

`grep '^.*indexer '` is the operator-friendly filter. Counting `event=disconnected` vs `event=reconnected` per peer-restart cycle is the recommended fault-injection assertion. `event=node-replaying` lines reveal that the upstream relay is alive but its ChainDB hasn't finished loading — operators can use the `attempt` counter to tell "stuck replaying" from "actually broken."

## Embedded use (cardano-tx-generator)

The cardano-tx-generator daemon (PR https://github.com/lambdasistemi/cardano-node-clients/pull/94) embeds the indexer. After this feature merges, the embedding code can drop any orchestrator-level `restart: always` workaround and rely on in-process reconnect.

Embedders that want to route `N2CEvent`s into their own tracer can pass a custom `Tracer IO N2CEvent` to `runDaemon` (the public field added on `DaemonConfig`).

## Operator expectations

- Disconnect events log as `indexer event=disconnected reason=...`, single-line, no backtrace.
- During disconnect, `ready` returns `false` with an `upstream` object — consumers should treat this as "wait and try again", same as bootstrap.
- After a long upstream outage, the supervisor's chain-sync backoff is capped at `--reconnect-max-ms` (default 30 s); recovery is bounded by that cap.
- The probe **does not** time out by default — `--node-ready-timeout-ms` left unset means the probe waits forever for chain replay. Set it explicitly for CI scenarios.
