# Implementation Plan: Tx History Indexer Library

## Modules

- `lib-tx-history-indexer/Cardano/Node/Client/TxHistoryIndexer/Types.hs`
- `lib-tx-history-indexer/Cardano/Node/Client/TxHistoryIndexer/Columns.hs`
- `lib-tx-history-indexer/Cardano/Node/Client/TxHistoryIndexer/Indexer.hs`
- `lib-tx-history-indexer/Cardano/Node/Client/TxHistoryIndexer/BlockExtract.hs`
- Follower integration in the existing indexer path as narrowly as
  needed to share one chain-sync session.

## Cursor Model

The implementation must choose and document one safe model:

- shared cursor/rollback log with a combined inverse, or
- same chain-sync session with separate persisted cursors whose resume
  point is the oldest safe point across attached stores.

If the safe model requires a public API expansion outside this issue,
stop with a Q-file before implementing it.

## Testing

- Unit tests for tenant-prefix codecs and ordered scans.
- Unit tests for rollback deleting history entries above the target.
- Reopen/restart test showing entries are not duplicated.
- A follower-level test proving the new history path is driven from the
  same chain-sync roll-forward path rather than a second runner.

## Gate

```bash
./gate.sh
```
