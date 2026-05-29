# Feature Spec: Tx History Indexer Library

## User Story

As a downstream treasury application, I can attach a decoder-agnostic
transaction-history indexer to the existing indexer chain-sync path and
query `(slot, txid, role)` entries by tenant and scope after restart and
rollback.

## Acceptance

- Add public sublibrary `tx-history-indexer-lib`.
- Store history in RocksDB-compatible typed columns.
- Prefix every persisted history key by tenant id.
- Provide one ordered query key:
  `(tenant_id, scope, slot, txid) -> role`.
- Expose a `BlockTx` payload and a
  `DecodeTx = BlockTx -> Maybe [TxSummaryEntry]` plug point.
- Drive history from the same chain-sync session as the UTxO indexer in
  the downstream service; no second chain-sync runner.
- Prove tenant isolation, rollback above a slot, and restart/resume.

## Constraint

The existing `csHandlers :: NonEmpty (IndexerHandler Cols [UtxoOp])`
fanout cannot decode treasury redeemers because it only receives UTxO
operations and only writes UTxO columns. This ticket must introduce the
missing shared-follower shape rather than abusing `csBlockTracer`.
