---
name: cardano-node-clients-guide
description: >-
  Guide for working in the lambdasistemi/cardano-node-clients Haskell
  repository — channel-driven Cardano node Ouroboros mini-protocol
  clients (N2C + N2N). Load when a task touches this repo: the
  utxo-indexer or cardano-adversary daemons; the Provider/Submitter
  record-of-functions interfaces (mkN2CProvider, mkN2CSubmitter); N2C
  LocalStateQuery / LocalTxSubmission / ChainSync over a Unix socket
  (runNodeClient, runNodeClientFull, LSQChannel, LTxSChannel,
  NodeToClientV_23, CardanoNodeToClientVersion19); the reconnect
  supervisor and LSQ tip probe (issue #97, waitForNodeReady,
  IndexerNodeReplaying, intersectNotFound, TimeTranslationPastHorizon);
  horizon-aware validity (ValidityChoice, AutoLongest, MaxHours,
  ExactlyHours, queryUpperBoundSlot); the block-indexer engine and the
  utxo-indexer-lib / tx-history-indexer-lib sublibraries (kv-transactions,
  RocksDB columns, rollback log, await/utxos_at NDJSON wire); the N2N
  adversary (chain_sync_flap, tracer-sidecar chain points,
  antithesis_random). Modules live under Cardano.Node.Client.*. Build
  with `nix develop -c just build`. Note: transaction building/balancing
  /tx-diff moved to the separate cardano-tx-tools repo.
---

# cardano-node-clients guide

Channel-driven Haskell clients for the Cardano node Ouroboros
mini-protocols, plus an indexer stack and an N2N adversary. Two
executables ship: `utxo-indexer` and `cardano-adversary`.

## Repository map

| Path | Purpose |
|------|---------|
| `lib/Cardano/Node/Client/` | Main library. `Provider.hs`, `Submitter.hs`, `Validity.hs`, `Address.hs`, `Ledger.hs` (`ConwayTx` alias), `Types.hs` (`Block`). |
| `lib/Cardano/Node/Client/N2C/` | N2C transport: `Connection` (`runNodeClient(Full)`), `LocalStateQuery`, `LocalTxSubmission`, `ChainSync`, `Codecs`, `Provider` (`mkN2CProvider`), `Submitter` (`mkN2CSubmitter`), `Probe` (LSQ tip readiness), `Reconnect` (retry supervisor), `Trace` (`N2CEvent`), `Types` (channels). |
| `lib/Cardano/Node/Client/Adversary/` | N2N adversary: `Daemon`, `Server` (NDJSON wire), `Application` (`chain_sync_flap`), `ChainPoints`, `RandomSource`, `Types`, `ChainSync/` (N2N codec + connection). |
| `lib/Cardano/Node/Client/UTxOIndexer/` | Bundled daemon: `Daemon`, `Follower` (`withChainSyncFollower`), `Server` (NDJSON), `Provider`, `BlockExtract`. |
| `lib-block-indexer/` | Sublibrary `block-indexer`: `Engine`, `Handler`, `Readiness`, `Types`. Domain-neutral rollback-log engine. |
| `lib-utxo-indexer/` | Sublibrary `utxo-indexer-lib`: `Columns`, `Indexer`, `IndexerOp`, `Types`. Concrete UTxO store over `kv-transactions`. |
| `lib-tx-history-indexer/` | Sublibrary `tx-history-indexer-lib`: `Columns`, `Indexer`, `BlockExtract`, `Types`. Multi-tenant history. |
| `app/utxo-indexer/` | `Main.hs` (CLI parsing) + `README.md`. |
| `app/cardano-adversary/` | `Main.hs` (CLI parsing). |
| `e2e-test/` | Sublibrary `devnet`: `withCardanoNode`, `Devnet`, `Setup`, `ChainPopulator`, `CrashRecovery`. |
| `test/` | `unit-tests` and `e2e-tests` suites. |
| `docs/`, `mkdocs.yml` | mkdocs site. `specs/` holds Spec Kit feature artifacts. |
| `flake.nix`, `justfile`, `cabal.project`, `nix/` | Build tooling. |

## Build, test, run

All inside the Nix dev shell; `just` pins `-O0`.

```bash
nix develop -c just build   # library + utxo-indexer + cardano-adversary
nix develop -c just unit    # unit-tests
nix develop -c just e2e     # e2e-tests (spawns a real cardano-node devnet)
nix develop -c just ci      # build + unit + cabal-fmt -c + fourmolu check + hlint
nix develop -c just format  # fourmolu -i + cabal-fmt -i
nix run .#utxo-indexer
nix run .#cardano-adversary
```

A single component: `cabal build cardano-node-clients:lib:cardano-node-clients -O0`.
GHC is `ghc9123`; the package is `GHC2021`. To see all GHC errors add
`--ghc-options="-fmax-errors=0"`.

## Navigating the code

- **Entry points** are CLI-parsing-only: `app/utxo-indexer/Main.hs`
  delegates to `UTxOIndexer.Daemon.runDaemon`;
  `app/cardano-adversary/Main.hs` delegates to
  `Adversary.Daemon.runDaemon`.
- **Querying the node**: the `Provider` record is defined in
  `lib/.../Provider.hs`; the live N2C implementation (each field) is in
  `lib/.../N2C/Provider.hs`. Submission mirrors this in `Submitter.hs`
  / `N2C/Submitter.hs`.
- **The protocol loop**: `N2C/Connection.hs` multiplexes mini-protocols
  5/6/7 (`runNodeClientFull` adds ChainSync). Channel plumbing
  (`LSQChannel`, `LTxSChannel`, `TBQueue`/`TMVar`) is in `N2C/Types.hs`.
- **Reconnect/readiness**: `N2C/Reconnect.hs` (retry supervisor) calls
  `N2C/Probe.hs` (`waitForNodeReady`) before attaching ChainSync. Trace
  events for grepping are in `N2C/Trace.hs`.
- **Indexer feature logic**: apply/rollback/await live in
  `lib-utxo-indexer/.../Indexer.hs`; storage layout in `Columns.hs`;
  generic engine in `lib-block-indexer/.../Engine.hs`. The daemon glues
  follower + server in `lib/.../UTxOIndexer/Daemon.hs`.
- **Adversary wire**: schemas in
  `specs/036-cardano-adversary/contracts/control-wire.md`; types in
  `Adversary/Types.hs`; dispatch in `Adversary/Server.hs`; the
  misbehaviour body in `Adversary/Application.hs`.

## Using the artifacts

`utxo-indexer` (required flags `--relay-socket`, `--listen`,
`--network-magic`, `--byron-epoch-slots`):

```bash
utxo-indexer --relay-socket /run/cardano-node/node.socket \
  --listen /tmp/idx.sock --network-magic 764824073 --byron-epoch-slots 21600
printf '{"ready": null}\n'                 | nc -U /tmp/idx.sock
printf '{"utxos_at": "<hex-addr>"}\n'      | nc -U /tmp/idx.sock
```

`cardano-adversary` (required `--control-socket`, `--network-magic`):

```bash
cardano-adversary --control-socket /tmp/adv.sock --network-magic 42 \
  --producer-host relay.example --chain-points-file /tmp/points
printf '{"chain_sync_flap":{"seed":1,"limit":50,"n_conns":4}}\n' | nc -U /tmp/adv.sock
```

Library:

```haskell
lsqCh <- newLSQChannel 16; ltxsCh <- newLTxSChannel 16
_ <- async $ runNodeClient (NetworkMagic 764824073) sock lsqCh ltxsCh
let provider = mkN2CProvider lsqCh; submitter = mkN2CSubmitter ltxsCh
```

## Answering questions

- "What does this repo do / how do I install it?" → `README.md`
  (What-is-this, Install, Quickstart) and the docs site landing page
  `docs/index.md`.
- "How do I run / configure the indexer? what flags / what wire?" →
  `app/utxo-indexer/README.md` and `docs/usage/utxo-indexer.md` (verified
  against `app/utxo-indexer/Main.hs`).
- "How does the adversary work?" → `docs/usage/cardano-adversary.md`
  and the control-wire spec under `specs/036-cardano-adversary/`.
- "What queries can I run against a node?" → `docs/modules/provider.md`
  and the `Provider` record in `lib/.../Provider.hs`.
- "How does it survive node restarts?" → reconnect/probe sections in
  `docs/architecture.md` and `app/utxo-indexer/README.md` (issue #97);
  source in `N2C/Reconnect.hs` and `N2C/Probe.hs`.
- "Where did tx-diff / TxBuild / balancing go?" → moved to
  [cardano-tx-tools](https://github.com/lambdasistemi/cardano-tx-tools);
  see the CHANGELOG "Unreleased" breaking-changes note.
- "How is the architecture laid out?" → `docs/architecture.md` (mermaid)
  and `docs/modules/indexers.md`.
