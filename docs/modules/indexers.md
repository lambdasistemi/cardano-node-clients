# Indexers

The indexer stack is split across three components so consumers depend
only on what they need. All three persist through the
`kv-transactions` abstraction (RocksDB or in-memory backend) and apply
every block's mutations in the same transaction that records its
rollback point.

## block-indexer

::: {.module}
`Cardano.Node.Client.BlockIndexer.*` (sublibrary
`cardano-node-clients:block-indexer`)
:::

The domain-neutral engine. It owns concerns independent of any
indexed domain:

- `Engine` — rollback-log watermarks, restoration/following phase
  threading, rollback-log pruning counters, and replay/conflict
  classification.
- `Handler` — a transaction-level `IndexerHandler` interface over a
  typed column GADT and inverse type, plus composition helpers that
  adapt one or more handlers to the chain-follower
  `Restoring`/`Following` interface. Multiple domain handlers can
  share one chain-sync subscription while preserving atomic block
  application.
- `Readiness` — generic readiness state and lag math, parameterised
  over slot and upstream-status types so it does not depend on any
  concrete reconnect module.

This sublibrary has **no** dependency on UTxO columns, `InterestSet`,
`UtxoOp`, or the Cardano node transport.

## utxo-indexer-lib

::: {.module}
`Cardano.Node.Client.UTxOIndexer.{Columns,Indexer,IndexerOp,Types}`
(sublibrary `cardano-node-clients:utxo-indexer-lib`)
:::

The concrete address→UTxO store. Three typed columns:

- `TxInCol :: KV TxIn Address` — primary table keyed by `TxIn`, so a
  block consuming an input can resolve its address without scanning.
- `AddressIndex :: KV AddrKey TxOut` — secondary index with composite
  key `lenByte || address || txId || ix`, so a cursor seek to
  `lenByte || address` yields every UTxO at that address with its full
  `TxOut` inline.
- `RollbackCol :: KV SlotNo (RollbackPoint [UtxoOp] BlockHash)` —
  slot-keyed inverse-op log (8-byte big-endian key, so cursor order
  matches slot order) used to undo apply-block writes on a chain-sync
  rollback.

`Indexer` exposes `applyAtSlot` (commit a batch of create/spend ops
plus the inverse log in one transaction, waking `await` waiters),
`rollbackTo` (replay the inverse log for every slot past the target),
`pruneRollbacks` (cap the log at the security parameter `k`), and the
follower-block wrappers used during cold sync.

## tx-history-indexer-lib

::: {.module}
`Cardano.Node.Client.TxHistoryIndexer.*` (sublibrary
`cardano-node-clients:tx-history-indexer-lib`)
:::

A multi-tenant transaction-history store. Each entry is filed under a
composite `TxSummaryKey` whose on-disk byte form orders entries by
`(tenant, scope, slot, txid, role)`:

```
key = lenTenant || tenant || lenScope || scope
        || slotBE(8) || txidLen(2 BE) || txid || roleLen(2 BE) || role
```

Variable-length tenant and scope ids are length-prefixed so prefix
scans stay correct across mixed lengths (tenant `"a"` never bleeds
into tenant `"ab"`). `appendSummaries` files a batch of detailed
`TxSummary` rows and maintains a tenant-local tx-id lookup;
`queryHistory` returns every entry of a single `(tenant, scope)`
ordered by `(slot, txid, role)`. A slot-aware resumable surface
(`processHistoryBlock`) lets the shared chain-sync follower drive this
store and the UTxO store through separate persisted cursors, resuming
from the oldest safe point across both.

## Bundled daemon and follower

::: {.module}
`Cardano.Node.Client.UTxOIndexer.{Daemon,Follower,Server,Provider,BlockExtract}`
(main library)
:::

`Daemon.runDaemon` wires an `IndexerHandle` (opened locally, RocksDB
or in-memory) to the chain-sync follower over the reconnect supervisor
and the NDJSON `Server`. `Follower.withChainSyncFollower` exposes the
follower as a standalone bracketed resource against a **caller-owned**
handle, so an embedder (for example an HTTP container that owns the
RocksDB store) can run the follower without the socket server.
`BlockExtract` decodes each consensus block into `(SlotNo, [UtxoOp])`
era-polymorphically via `cardano-ledger-read`. See the
[utxo-indexer manual](../usage/utxo-indexer.md) for the daemon's CLI
and wire protocol.
