# Implementation Plan: lib-block-indexer multi-handler refactor

**Branch**: `feat/166-lib-block-indexer-multi-handler` | **Date**: 2026-05-27 | **Spec**: [spec.md](./spec.md)  
**Issue**: [#166](https://github.com/lambdasistemi/cardano-node-clients/issues/166)  
**PR**: [#167](https://github.com/lambdasistemi/cardano-node-clients/pull/167)

## Summary

Factor the generic block-stream indexing machinery out of
`lib-utxo-indexer` into a new public `block-indexer` sublibrary, then port
the UTxO indexer onto a handler interface that can compose multiple handlers
inside one chain-sync subscription and one block transaction. The delivered
branch remains behavior-equivalent for existing UTxO indexer consumers and
does not add tx-history or other derived downstream columns.

## Technical Context

**Language/Version**: Haskell, GHC2021, GHC 9.12.3 through Nix  
**Primary Dependencies**: `chain-follower`, `rocksdb-kv-transactions`,
`rocksdb-haskell-jprupp`, `stm`, Cardano consensus/network libraries already
in the package  
**Storage**: RocksDB and in-memory `kv-transactions` backends  
**Testing**: Hspec unit tests, devnet e2e tests, `./gate.sh`  
**Target**: Public Cabal sublibraries in `cardano-node-clients`  
**Performance Goal**: Preserve the #165 restoration/following split so
historical cold-sync blocks outside the stability window do not compute full
rollback inverses.  
**Constraints**: Refactor-only; no `InterestSet` semantic changes; no
`chain-follower` changes; no tx-history columns.

## Constitution Check

- Channel-driven N2C clients: preserved. ChainSync remains the separate
  stream; this PR only changes the indexing wrapper around it.
- Devnet E2E testing: preserved. Existing e2e tests remain in the gate and
  must pass after each accepted slice.
- Minimal dependencies: no new external package dependencies planned. The new
  sublibrary depends only on dependencies already used by the existing UTxO
  follower/indexer path.
- Test utilities first-class: preserved. Any generic test helper needed for
  multi-handler proof should live in the test suite, not in downstream apps.

## Current Code Map

- `lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs` currently
  mixes UTxO state, waiters, RocksDB/in-memory constructors, rollback log
  handling, `Runner.processBlock` phase state, and apply/rollback operations.
- `lib/Cardano/Node/Client/UTxOIndexer/Follower.hs` currently mixes
  chain-sync bring-up, reconnect supervision, readiness state, lag threshold
  interpretation, `InterestSet` filtering, EBB skipping, and UTxO handler
  invocation.
- `lib/Cardano/Node/Client/UTxOIndexer/BlockExtract.hs`,
  `lib-utxo-indexer/.../Columns.hs`, `IndexerOp.hs`, and `Types.hs` are
  UTxO-domain code and should remain UTxO-owned unless the slice brief says
  otherwise.
- Existing tests in `FollowerSpec`, `IndexerSpec`, `PersistenceSpec`, and e2e
  reconnect specs are the main behavior-equivalence proof.

## Target Project Structure

```text
lib-block-indexer/
└── Cardano/Node/Client/BlockIndexer/
    ├── Engine.hs        # chain-follower wrapper, handler composition, transactions
    ├── Handler.hs       # IndexerHandler and composite handler types
    ├── Readiness.hs     # generic Readiness + lag guard helpers
    └── Types.hs         # generic block metadata and phase-facing types

lib-utxo-indexer/
└── Cardano/Node/Client/UTxOIndexer/
    ├── Indexer.hs       # UTxO state/query API, smaller storage handle
    ├── Follower.hs      # compatibility wrapper over BlockIndexer.Engine
    └── ...              # Columns, IndexerOp, Types stay UTxO-specific
```

The exact module split may adjust during implementation, but the ownership
boundary must stay stable: generic chain-sync/indexer mechanics in
`Cardano.Node.Client.BlockIndexer.*`, UTxO columns/query behavior in
`Cardano.Node.Client.UTxOIndexer.*`.

## Design

1. Add a public Cabal sublibrary named `block-indexer` with empty or minimal
   modules first so downstream slices can move code without combining package
   scaffolding with behavior changes.
2. Move the opaque `Runner.processBlock` phase wrapper and transaction shell
   out of `UTxOIndexer.Indexer`. Keep a single UTxO handler path during the
   move so the first behavior-changing slice is mechanically reviewable.
3. Move generic readiness state and slot-lag guard helpers out of
   `UTxOIndexer.Follower` into `BlockIndexer.Readiness`; leave daemon
   `ReadyStatus` JSON encoding in `UTxOIndexer.Server`.
4. Introduce `IndexerHandler cols inv` and engine-level composition. The
   engine should apply all registered handlers under one transaction and store
   a composite inverse for followed blocks. Rollback should fan out using that
   composite inverse.
5. Port the current UTxO apply/rollback logic into
   `liveUtxoHandler :: InterestSet -> IndexerHandler Cols [UtxoOp]`.
   `filterBlockOps` behavior is unchanged and remains covered by existing
   tests.
6. Keep compatibility wrappers so existing callers of `withInMemoryIndexer`,
   `withRocksDBIndexer`, `withChainSyncFollower`, `snapshotAt`, and
   `awaitTxIn` continue to compile.
7. Add a focused multi-handler unit test with a trivial second handler. The
   second handler should prove composition and rollback without introducing a
   downstream domain concept or new derived production column.

## Slice Plan

1. **Package shell**: Add `block-indexer` sublibrary and module skeletons; no
   behavior moved.
2. **Single-handler engine move**: Move phase dispatch and rollback transaction
   shell behind the new engine while still driving only the current UTxO logic.
3. **Readiness and lag guard**: Move generic readiness and lag calculation into
   `lib-block-indexer`; keep UTxO daemon wire conversion unchanged.
4. **Multi-handler composition**: Add handler composition and composite inverse
   support; port `liveUtxoHandler` to the new interface.
5. **Public exports and Haddock**: Stabilize exposed modules and compatibility
   docs for both `block-indexer` and `utxo-indexer-lib`.
6. **Tests and proof**: Add the multi-handler proof and run the full gate.
7. **Finalization**: Audit task completion, update PR body, pass the gate, and
   drop `gate.sh` in the final chore commit.

## Verification

Run after each accepted implementation slice:

```bash
./gate.sh
```

Focused commands workers may use while iterating:

```bash
nix develop --quiet -c cabal build all -O0
nix develop --quiet -c just unit
nix develop --quiet -c cabal test cardano-node-clients:unit-tests -O0 --test-show-details=direct --test-options="--match=multi-handler"
```

The final gate must include build-all, unit, e2e, Cabal format check,
Fourmolu check, and HLint via `./gate.sh`.

## Non-Goals Guardrail

- Do not add tx-history, audit-trail, or other downstream derived columns.
- Do not change `chain-follower`.
- Do not change `InterestSet` behavior.
- Do not delete downstream Amaru copies in this PR; downstream cleanup happens
  in a separate repository/PR after `lib-block-indexer` is available.
