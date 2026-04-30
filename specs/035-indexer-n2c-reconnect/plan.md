# Implementation Plan: utxo-indexer auto-reconnect on N2C peer close

**Branch**: `035-indexer-n2c-reconnect` | **Date**: 2026-04-30
**Spec**: `specs/035-indexer-n2c-reconnect/spec.md`
**Issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/97
**Regression test (already on main)**: https://github.com/lambdasistemi/cardano-node-clients/pull/100
**Prometheus follow-up**: https://github.com/lambdasistemi/cardano-node-clients/issues/101

## Summary

Wrap the `runChainSyncN2C` call in `Daemon.runDaemon` with a reconnect supervisor built on top of `Control.Retry`. Before each chain-sync attempt, probe the upstream node via LSQ (`Acquire VolatileTip` + `GetCurrentTip`) and only enter chain-sync once the probe sees a non-Origin tip. Surface disconnects as a structured `upstream` JSON object on the `ready` response and as `N2CEvent`s on a `Tracer IO N2CEvent`.

No protocol changes. No persistence schema changes. The existing `getResumePoints` resume path is reused unchanged.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches the repo's haskell.nix pin)
**Primary Dependencies**: `ouroboros-network`, `cardano-ledger-*`, `chain-follower`, `Control.Tracer`, `Control.Retry` (already in the dep closure — verified via `dist-newstyle/cache/plan.json`), `async`, `stm`
**Storage**: RocksDB resume points already persisted by PR #90 — no schema changes
**Testing**: hspec + the in-tree devnet (`withRestartableCardanoNode`, landed via PR #100); unit tests for the supervisor's value-level decisions
**Target Platform**: Linux x86_64 (devnet + Antithesis container workload)
**Project Type**: Haskell library + executable (single project, infrastructure library)
**Performance Goals**: SC-002 — reconnect within `≤ 3×` the relay's restart-to-tip time
**Constraints**: No protocol changes; backoff defaults match issue body (1 s → 30 s); probe timeout default unbounded; supervisor must propagate `AsyncCancelled` for clean shutdown
**Scale/Scope**: Single upstream peer per indexer process; supervisor must tolerate ≥ 50 successive disconnects (SC-001)

## Constitution Check

Constitution: `.specify/memory/constitution.md` v1.0.0.

| Principle | Compliance |
|-----------|------------|
| I. Channel-Driven N2C Clients | ✅ Reuses `runChainSyncN2C` and `runNodeClient`; supervisor and probe sit *above* the channel layer, not inside it. |
| II. Devnet E2E Testing | ✅ `UTxOIndexerReconnectSpec` exercises supervisor + probe against a real devnet via `withRestartableCardanoNode`. |
| III. Minimal Dependencies | ✅ Adds `, retry` to the library `build-depends`; the package is already in the transitive closure, no flake change. |
| IV. Test Utilities Are First-Class | ✅ `Probe.waitForNodeReady` lives in the public library so consumers (e.g. test-helper `restartNode` and the `cardano-tx-generator` daemon) can reuse it. |

Quality gates (`just ci`, fourmolu, hlint, cabal-check, no mocks for node communication) all apply unchanged.

**Result**: PASS.

## Project Structure

### Documentation (this feature)

```text
specs/035-indexer-n2c-reconnect/
├── plan.md
├── research.md          # decisions, alternatives
├── data-model.md        # ReconnectPolicy, ProbeConfig, IndexerEvent, UpstreamStatus, ReadyStatus ext
├── quickstart.md        # reproducer + CLI flags
├── contracts/
│   └── control-wire.md  # additive 'upstream' field on ready response
└── checklists/requirements.md
```

### Source Code

```text
lib/Cardano/Node/Client/UTxOIndexer/
├── Daemon.hs            # MODIFY: take Tracer arg; wire probe + supervisor
├── Probe.hs             # NEW: waitForNodeReady (LSQ tip probe wrapped in retry)
├── Reconnect.hs         # NEW: runReconnectLoop (Control.Retry-based supervisor)
├── Server.hs            # MODIFY: extend ReadyStatus with rsUpstream; encoder emits 'upstream'
└── Trace.hs             # NEW: N2CEvent ADT (incl. IndexerNodeReplaying) + stderr renderer

app/utxo-indexer/
├── Main.hs              # MODIFY: parse new CLI flags; install stderr tracer
└── README.md            # NEW: document flags + reconnect behaviour

test/Cardano/Node/Client/E2E/
└── UTxOIndexerReconnectSpec.hs   # NEW: full E2E covering US1/US2/US3
```

**Structure Decision**: Single-project Haskell layout. **Probe and Reconnect are split into separate modules** so the probe primitive (`waitForNodeReady`) is independently usable — the test helper's `restartNode` calls it directly to replace the current 10s `threadDelay` with a real readiness check.

## Phase 0: Research → `research.md`

All open questions resolved. Key resolved decisions:

- Use `Control.Retry` (already in dep closure) instead of hand-rolling backoff.
- Probe = `Acquire VolatileTip` + `GetCurrentTip`, ready ⇔ tip ≠ Origin.
- Default probe timeout = unbounded; emit `IndexerNodeReplaying` periodically while waiting.
- Prometheus `blockReplayProgress` UX deferred to https://github.com/lambdasistemi/cardano-node-clients/issues/101.

## Phase 1: Design & Contracts

### Data model — `data-model.md`

`ReconnectPolicy`, `ProbeConfig`, `UpstreamStatus`, `DisconnectInfo`, `N2CEvent` (with new `IndexerNodeReplaying`), `ReadyStatus` extension.

### Contracts — `contracts/control-wire.md`

`ready` response gains an optional `upstream` object when disconnected. Backwards-compatible.

### Quickstart — `quickstart.md`

Reproducer (matches issue #97), new CLI flags, operator notes.

## Complexity Tracking

> No violations. Section intentionally empty.
