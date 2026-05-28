# Feature Specification: ChainSyncConfig Handler-List Seam

**Feature Branch**: `feat/168-csHandlers-seam`
**Issue**: #168
**Created**: 2026-05-28
**Status**: Draft

## User Story

As an in-process UTxO indexer consumer, I can pass a non-empty handler
list to `withChainSyncFollower` through `ChainSyncConfig`, so I can run
the existing live UTxO handler and a second derived handler in the same
chain-sync follower without copy-pasting the follower wiring.

## Functional Requirements

- **FR-001**: `ChainSyncConfig` exposes `csHandlers :: NonEmpty (IndexerHandler Cols [UtxoOp])`.
- **FR-002**: `withChainSyncFollower` uses `csHandlers` for the follower's block-indexer engine instead of reconstructing `liveUtxoHandler` internally.
- **FR-003**: Existing daemon and test configurations explicitly pass `liveUtxoHandler csInterestSet :| []`, preserving the current behavior.
- **FR-004**: The public UTxO follower API keeps `csInterestSet` because it remains the configuration value used by the bundled UTxO handler and waiters.
- **FR-005**: A unit regression wires `liveUtxoHandler IndexAll :| [secondHandler]` and proves roll-forward writes both handlers' state and rollback restores both.
- **FR-006**: Haddock documents that consumers extending the follower should compose handler lists with the existing `IndexerHandler` helpers from `block-indexer`.

## Non-Goals

- No new tx-history handler in this repository.
- No semantic change to `InterestSet`, UTxO filtering, rollback retention, reconnect, readiness, or N2C chain-sync behavior.
- No new parallel `withChainSyncFollowerHandlers` entry point.
- No daemon CLI or wire protocol change.

## Acceptance Criteria

- All existing `ChainSyncConfig` construction sites compile with explicit `csHandlers`.
- `withChainSyncFollower` can run with a second handler supplied by the caller.
- Existing `liveUtxoHandler IndexAll :| []` behavior is unchanged for bundled daemon and current tests.
- `./gate.sh` passes at PR head.
