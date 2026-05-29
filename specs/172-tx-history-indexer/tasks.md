# Tasks: Tx History Indexer Library

## Slice 1 — Storage Foundation

- [X] T172-S1 Add cabal sublibrary stanza.
- [X] T172-S1 Add history types and tenant-prefixed key codecs.
- [X] T172-S1 Add in-memory and RocksDB open/query API.
- [X] T172-S1 Prove tenant isolation and ordered scope scans.
- [X] T172-S1 Commit:
  `feat(tx-history): add tenant-prefixed history storage`.

## Slice 2 — Shared Follower

- [X] T172-S2 Add Conway `BlockTx` extraction.
- [X] T172-S2 Add the same-chain-sync history integration.
- [X] T172-S2 Prove rollback above slot N drops history entries.
- [X] T172-S2 Prove restart/resume does not duplicate entries.
- [X] T172-S2 Document the selected cursor model.
- [X] T172-S2 Make the downstream `DecodeTx` contract slot-aware.
- [X] T172-S2 Commit:
  `feat(tx-history): share chain-sync with history indexing`.

## Slice 3 — Finalization

- [X] T172-S3 Run `./gate.sh`.
- [X] T172-S3 Update PR body with downstream proof link.
- [X] T172-S3 Drop `gate.sh` before ready.
