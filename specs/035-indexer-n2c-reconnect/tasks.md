---
description: "Task list for feature 035-indexer-n2c-reconnect"
---

# Tasks: utxo-indexer auto-reconnect on N2C peer close

**Input**: Design documents from `specs/035-indexer-n2c-reconnect/`
**Prerequisites**: [plan.md](plan.md) (required), [spec.md](spec.md) (required), [research.md](research.md), [data-model.md](data-model.md), [contracts/control-wire.md](contracts/control-wire.md), [quickstart.md](quickstart.md)

**Source issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/97
**Regression test (already on main)**: https://github.com/lambdasistemi/cardano-node-clients/pull/100
**Prometheus follow-up**: https://github.com/lambdasistemi/cardano-node-clients/issues/101

**Per the `pr` skill, each task is one vertical commit**: bisect-safe (`just ci` green at every commit), no fixup commits — review feedback retroactively edits the originating commit via stgit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Independent of any pending task — safe to take in parallel.
- **[Story]**: User story label (US1, US2, US3) for story-phase tasks.

---

## Phase 1: Setup (Shared Infrastructure)

- [x] **T001** — Branch `035-indexer-n2c-reconnect` rebased on origin/main (which already contains the regression test from PR #100). Spec docs updated to match the new design (probe + retry library).

---

## Phase 2: Foundational (Blocking Prerequisites)

- [ ] **T002** — Cabal: add `, retry` to the library `build-depends`. Add new exposed-modules `Cardano.Node.Client.N2C.Probe`, `Cardano.Node.Client.N2C.Reconnect`, `Cardano.Node.Client.N2C.Trace`. Empty stubs.
  Files: `cardano-node-clients.cabal`, three new stub files.
  Bisect-safe gate: `nix develop -c just ci` build + cabal-check.

- [ ] **T003** — Implement `N2CEvent` ADT and `defaultStderrTracer` in `Trace.hs` per [data-model.md § IndexerEvent](data-model.md#indexerevent-new--cardanonodeclientutxoindexertrace) — including the new `IndexerNodeReplaying` constructor for the probe loop.
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Trace.hs`, `test/Cardano/Node/Client/UTxOIndexer/TraceSpec.hs` (renderer unit tests).
  Bisect-safe gate: `just ci` + new unit tests green.

---

## Phase 3: User Story 1 — Process survives + reconnects (Priority: P1) 🎯 MVP

- [ ] **T004** [US1] — Implement `Cardano.Node.Client.N2C.Probe.waitForNodeReady` per [research.md § D6](research.md#d6-node-ready-probe--lsq-tip-query-with-unbounded-timeout). Opens an LSQ-only N2C connection via `runNodeClient`, sends `MsgAcquire VolatileTip`, runs `GetCurrentTip`, succeeds when the response is non-Origin. Wrapped in `Control.Retry.recoverAll (capDelay (pcRetryMaxMs * 1000) (exponentialBackoff (pcRetryBaseMs * 1000)))`. On each retry attempt, emits `IndexerNodeReplaying`. Honors `pcTimeoutMs` if `Just`.
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Probe.hs`, `test/Cardano/Node/Client/UTxOIndexer/ProbeSpec.hs` (unit: `ProbeConfig` defaults, retry-policy mapping).
  Satisfies: FR-002 (readiness side).
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T005** [US1] — Implement `runReconnectLoop` in `Reconnect.hs` using `Control.Retry.retryingDynamic` per [research.md § D2](research.md#d2-backoff-implementation--retry-library-not-hand-rolled). Each iteration: probe (T004) → run chain-sync → on synchronous failure, return `ConsultPolicy`; on async exception or clean return, return `DontRetry`. Emits `IndexerDisconnected`, `IndexerReconnecting`, `IndexerReconnected`. Reset-threshold logic on top of `retry` (separate `RetryStatus` reset after a healthy run).
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Reconnect.hs`, `test/Cardano/Node/Client/UTxOIndexer/ReconnectSpec.hs` (unit: cancellation propagation, value-level retry decisions, status-sink updates).
  Satisfies: FR-001, FR-002, FR-010, FR-011, FR-012, FR-013.
  Depends on: T004.
  Bisect-safe gate: `just ci` + unit tests green.

- [ ] **T006** [US1] — Wire probe + supervisor into `Daemon.runDaemon`. New signature: `runDaemon :: Tracer IO N2CEvent -> DaemonConfig -> IO ()`. `DaemonConfig` gains `dcReconnectPolicy :: ReconnectPolicy` and `dcProbeConfig :: ProbeConfig`. Replace the bare `chainAction = runChainSyncN2C ...` with `runReconnectLoop tracer policy probeConfig setStatus getProcessedSlot chainSession`. `runDaemon` emits `IndexerStarted` on entry and `IndexerStopped` on exit (via `onException`, NOT `bracket_` — bracket masks the body and breaks the supervisor's threadDelay/STM path).
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Daemon.hs`, update existing `test/Cardano/Node/Client/E2E/UTxOIndexerSpec.hs` to pass `nullIndexerTracer` + default policies.
  Satisfies: FR-001, FR-003 (resume path is unchanged — `getResumePoints` is recomputed inside the loop).
  Depends on: T005.
  Bisect-safe gate: `just ci` + existing `UTxOIndexerSpec` E2E green.

- [ ] **T007** [US1] — Replace the `threadDelay 1_000_000` post-spawn grace in `e2e-test/Cardano/Node/Client/E2E/Devnet.hs` (both in `withRestartableCardanoNode` and `restartNode`) with a call to `Probe.waitForNodeReady`. Tests become deterministic; the helper now uses the same primitive as the supervisor.
  Files: `e2e-test/Cardano/Node/Client/E2E/Devnet.hs`.
  Satisfies: test-infra alignment with production behaviour.
  Depends on: T004.
  Bisect-safe gate: `just ci` + existing E2Es still green (the existing `UTxOIndexerSpec` and `Issue97ReproSpec` use this helper).

---

## Phase 4: User Story 2 — Graceful degradation on read primitives (Priority: P2)

- [ ] **T008** [US2] — Add `UpstreamStatus` + `DisconnectInfo` types to `Reconnect.hs`. Extend `ReadyStatus` in `Server.hs` with `rsUpstream :: UpstreamStatus` per [data-model.md § ReadyStatus](data-model.md#readystatus-extended--cardanonodeclientutxoindexerserver). Update `ToJSON` encoder per [contracts/control-wire.md](contracts/control-wire.md) — additive `upstream` field, omitted when `UpstreamConnected`. Force `rsReady=False` whenever `rsUpstream = UpstreamDisconnected _`.
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Reconnect.hs`, `lib/Cardano/Node/Client/UTxOIndexer/Server.hs`, extend `test/Cardano/Node/Client/UTxOIndexer/ServerSpec.hs` for both connected and disconnected JSON variants.
  Satisfies: FR-005, FR-006 (response shape).
  Depends on: T005.
  Bisect-safe gate: `just ci` + extended unit tests green.

- [ ] **T009** [US2] — Plumb the supervisor's `setStatus` callback into `Daemon.runDaemon`'s `TVar ReadyStatus`. On `UpstreamDisconnected`, write `rsUpstream` and force `rsReady=False`. On `UpstreamConnected`, leave `rsReady` alone so the natural `updateReady` path can return `true` once chain-sync catches up.
  Files: `lib/Cardano/Node/Client/UTxOIndexer/Daemon.hs`.
  Satisfies: FR-005, FR-006 (producer side).
  Depends on: T008.
  Bisect-safe gate: `just ci` + existing E2E green.

---

## Phase 5: User Story 3 — Structured log events (Priority: P3)

- [ ] **T010** [US3] — Add CLI flags to `app/utxo-indexer/Main.hs`: `--reconnect-initial-ms` (default 1000), `--reconnect-max-ms` (default 30000), `--reconnect-reset-threshold-ms` (default 30000), `--node-ready-timeout-ms` (default unset / unbounded). Construct `ReconnectPolicy` and `ProbeConfig` from flags. Wire `defaultStderrTracer` (from Trace.hs) into `runDaemon`. Document the flags in `app/utxo-indexer/README.md`.
  Files: `app/utxo-indexer/Main.hs`, `app/utxo-indexer/README.md` (new).
  Satisfies: FR-007, FR-008, FR-009 (executable side).
  Depends on: T006.
  Bisect-safe gate: `just ci` + manual `utxo-indexer --help` shows new flags.

---

## Phase 6: End-to-end test

- [ ] **T011** [US1+US2+US3] — Implement `test/Cardano/Node/Client/E2E/UTxOIndexerReconnectSpec.hs` covering all three user stories in one test, per [quickstart.md § Run the new E2E](quickstart.md#run-the-new-e2e-post-fix). Uses a captured `Tracer IO N2CEvent` (writes events into a `TVar`). Asserts: daemon `Async` doesn't exit, listen socket stays open, `upstream` object visible during gap, `utxos_at` served during gap, `processedSlot` advances post-reconnect, captured event stream contains expected variants.
  Files: `test/Cardano/Node/Client/E2E/UTxOIndexerReconnectSpec.hs`, register in `test/main.hs`.
  Satisfies: SC-001..SC-006.
  Depends on: T010.
  Bisect-safe gate: `just ci` + new E2E green.

---

## Phase 7: Polish

- [ ] **T012** [P] — Update top-level `README.md` to mention the in-process auto-reconnect feature. Cross-link app README and issue #97.
  Files: `README.md`.
  Depends on: T011.

- [ ] **T013** [P] — Run `nix develop --quiet -c just ci` from a clean worktree. Fix any fourmolu/hlint/cabal-check issues by editing the originating commit via stgit (per *Always local CI* + *StGit retroactive fixes* feedback rules).
  Depends on: T011.

- [ ] **T014** — Force-push the rebased `035-indexer-n2c-reconnect` branch. Update PR #98 description with the new design + the link to PR #100 (regression that justifies it) + #101 (Prometheus follow-up). Notify the user with the PR URL — **do not merge without explicit authorisation**.
  Files: GitHub state only.
  Depends on: T012, T013.

---

## Dependency graph

```
T001 → T002 → T003
                │
                ▼
              T004 ──→ T005 ──→ T006 ──→ T008 ──→ T009 ──→ T010 ──→ T011 ──→ T012 ┐
                │                                                                 ├─→ T014
                └──→ T007 (parallel, depends only on T004)                  T013 ─┘
```

T012 and T013 may run in parallel after T011.

## Independent test surface

| Story | Spec section | Automated test |
|-------|--------------|----------------|
| US1   | [spec.md § US1](spec.md#user-story-1---indexer-survives-upstream-relay-restart-priority-p1) | `UTxOIndexerReconnectSpec` (T011) |
| US2   | [spec.md § US2](spec.md#user-story-2---read-primitives-degrade-gracefully-during-disconnect-priority-p2) | `UTxOIndexerReconnectSpec` extended (T011) |
| US3   | [spec.md § US3](spec.md#user-story-3---disconnectreconnect-events-are-observable-priority-p3) | `UTxOIndexerReconnectSpec` extended (T011) + `TraceSpec` (T003) |

## MVP scope

T001..T007 = US1 (the supervisor + probe alone). Self-contained: indexer survives relay restart, listen socket stays open, chain-sync resumes from last applied block. T008..T009 layer the `upstream` JSON. T010..T011 wire CLI flags + structured log assertions.
