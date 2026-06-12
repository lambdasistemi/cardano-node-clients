# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros
mini-protocols (N2C + N2N).

## Overview

This package provides high-level interfaces for communicating with a
Cardano node, plus indexers built on top of them:

- **Provider** — ledger queries: UTxOs (by address or `TxIn`),
  protocol parameters, ledger snapshot (era/tip/epoch), stake
  rewards, reward accounts, vote delegatees, treasury, governance
  state, POSIX-to-slot conversion, and horizon-aware validity bounds
  ([details](modules/provider.md))
- **Submitter** — submit signed Conway transactions
  ([details](modules/submitter.md))
- **N2C** — LocalStateQuery, LocalTxSubmission, and ChainSync over
  the node's Unix socket, with a reconnect supervisor and an LSQ tip
  probe ([details](modules/n2c.md))
- **Validity** — pick an `invalid-hereafter` slot inside the chain's
  plutus-translation horizon ([details](modules/validity.md))
- **Indexers** — a generic block-indexer engine plus concrete
  UTxO and transaction-history indexers
  ([details](modules/indexers.md))
- **Adversary** — N2N ChainSync misbehaviour for fault-injection
  testing, shipped as the `cardano-adversary` daemon
  ([manual](usage/cardano-adversary.md))

Transaction building, balancing, and blueprint-aware diffing (the
`tx-diff` and `cardano-tx-generator` executables) live in
[lambdasistemi/cardano-tx-tools](https://github.com/lambdasistemi/cardano-tx-tools).

The query/submit interfaces are protocol-agnostic
records-of-functions. Each transport protocol supplies its own
constructor:

| Protocol | Provider | Submitter |
|----------|----------|-----------|
| N2C (Unix socket) | `mkN2CProvider` | `mkN2CSubmitter` |

## Executables

- **utxo-indexer** — address→UTxO indexer daemon (in-memory or
  RocksDB-backed) exposing `ready`, `utxos_at`, and `await` over a
  Unix-socket NDJSON wire ([manual](usage/utxo-indexer.md))
- **cardano-adversary** — N2N adversary daemon serving `ready` and
  `chain_sync_flap` over a Unix-socket NDJSON control wire
  ([manual](usage/cardano-adversary.md))

See [Installation](installation.md) for release artifacts and Nix
invocations.

## Quick start

```haskell
import Cardano.Node.Client.N2C.Connection
import Cardano.Node.Client.N2C.Provider
import Cardano.Node.Client.N2C.Submitter
import Control.Concurrent.Async (async)
import Ouroboros.Network.Magic (NetworkMagic (..))

main :: IO ()
main = do
    lsqCh  <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    -- connect in background
    _ <- async $
        runNodeClient
            (NetworkMagic 764824073)  -- mainnet
            "/run/cardano-node/node.socket"
            lsqCh
            ltxsCh
    let provider  = mkN2CProvider lsqCh
        submitter = mkN2CSubmitter ltxsCh
    -- use provider / submitter ...
    pure ()
```

## Testing

- Unit tests cover the N2C probe and trace surface, the UTxO indexer
  (block extraction, daemon, follower, indexer, persistence,
  provider, server, shared follower, types, and a mainnet smoke
  test), the tx-history indexer, the block-indexer handler, the
  adversary chain-points parser and server, address parsing, and
  validity helpers.
- E2E tests run a real devnet `cardano-node` for ChainSync,
  horizon-aware validity, provider queries, the full N2C session,
  the UTxO indexer relay-restart reconnect scenario, and the issue
  [#97](https://github.com/lambdasistemi/cardano-node-clients/issues/97)
  reproduction.

## Build

```bash
nix develop -c just build   # compile
nix develop -c just ci      # build + unit + format/lint checks
```
