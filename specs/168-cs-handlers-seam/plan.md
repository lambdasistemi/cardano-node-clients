# Implementation Plan: ChainSyncConfig Handler-List Seam

## Context

PR #167 added the generic `IndexerHandler cols inv` interface and handler
composition helpers in `block-indexer`. The UTxO follower still hides that
interface because `ChainSyncConfig` has no handler-list field and the
follower path rebuilds the singleton UTxO handler internally.

## Technical Approach

- Add `csHandlers` to `Cardano.Node.Client.UTxOIndexer.Follower.ChainSyncConfig`.
- Keep `csInterestSet` for current UTxO semantics and waiter bookkeeping.
- Import the concrete handler types needed by the field:
  `IndexerHandler`, `Cols`, `UtxoOp`, and `NonEmpty`.
- Route the chain-follower state through caller-supplied handlers. Preserve
  the historical `IndexerHandle.newFollowerState :: Bool -> IO IndexerFollowerState`
  compatibility unless the driver finds the existing code requires a minimal
  additive helper.
- Update every `ChainSyncConfig` construction site to pass:
  `csHandlers = liveUtxoHandler <same-interest-set> :| []`.
- Add a focused regression beside the existing handler/follower tests. The
  test should use a trivial second handler that writes to a test-observable
  column, then assert both roll-forward and rollback behavior.
- Update Haddock on `ChainSyncConfig` and the follower module so downstream
  users discover `csHandlers` and reuse the existing handler composition
  helpers.

## Slices

### Slice 1: Add `csHandlers` Field

Add the field, imports, and `Show` rendering placeholder. Do not wire behavior
yet. Update construction sites only as needed for compilation.

### Slice 2: Wire Follower State to `csHandlers`

Replace the singleton handler construction on the high-level follower path
with the caller-provided handler list. Preserve existing UTxO behavior by
using the singleton default at current call sites.

### Slice 3: Multi-Handler Regression

Add the unit proof for `liveUtxoHandler IndexAll :| [secondHandler]` through
the seam. Include rollback symmetry.

### Slice 4: Haddock and Public Guidance

Document the new field and extension pattern, and verify module exports are
sufficient for downstream consumers to build handler lists.

## Verification

- Focused unit command for slice work:
  `nix develop --quiet -c cabal test cardano-node-clients:unit-tests -O0 --test-show-details=direct --test-options='--match /UTxOIndexer.Follower|/BlockIndexer.Handler'`
- Full gate:
  `./gate.sh`
