# Implementation Plan: cardano-tx-generator

**Branch**: `034-cardano-tx-generator` | **Date**: 2026-04-28 | **Spec**: [spec.md](spec.md)
**Tracking issue**: [lambdasistemi/cardano-node-clients#84](https://github.com/lambdasistemi/cardano-node-clients/issues/84)
**Blocked by**: [lambdasistemi/cardano-node-clients#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95) (combined N2C helper)
**Closes-Driving**: [cardano-foundation/cardano-node-antithesis#69](https://github.com/cardano-foundation/cardano-node-antithesis/issues/69)
**Downstream adoption**: [cardano-foundation/cardano-node-antithesis#78](https://github.com/cardano-foundation/cardano-node-antithesis/issues/78)

## Summary

A new `app/cardano-tx-generator/` executable + supporting library
modules. Embeds the merged in-tree address-to-UTxO indexer
([#79](https://github.com/lambdasistemi/cardano-node-clients/pull/79)),
opens **one** N2C connection to the relay (ChainSync + LSQ + LTxS
on the same mux session via [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)),
builds transactions with the in-tree TxBuild DSL, and exposes a
control wire (NDJSON over Unix socket) for the Antithesis composer
to drive one transaction (or one refill) per request with a
caller-supplied seed.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches repo).
**Primary Dependencies (in-tree)**:
[`utxo-indexer-lib`](https://github.com/lambdasistemi/cardano-node-clients/tree/main/lib-utxo-indexer),
TxBuild DSL (lib/Cardano/Node/Client/TxBuild/...), Balance,
N2C.{Connection,ChainSync,LocalTxSubmission,Provider}, E2E.Setup
(reusing `mkSignKey`, `enterpriseAddr`, `addKeyWitness`).
**Primary Dependencies (out of tree, already in cabal.project)**:
`cardano-ledger-conway`, `ouroboros-network`, `aeson`, `network`,
`stm`, `cryptonite` (for blake2b256), `random`.
**Storage**: two files in `--state-dir` (`master.seed` 32 bytes,
`next-hd-index` ASCII int) plus the embedded indexer's chosen
backend (in-memory v1, RocksDB optional).
**Testing**: `hspec` E2E against `withDevnet` (precedent:
[ChainPopulatorSpec](https://github.com/lambdasistemi/cardano-node-clients/tree/main/e2e-test)).
**Target Platform**: Linux x86_64 (cardano-node platform).
**Project Type**: single Haskell executable + supporting library.
**Performance Goals**: ≥ 1 confirmed tx/s under composer drive on
devnet; "not-applicable" responses return in ≤ 1 s (SC-004).
**Constraints**: determinism on the tx path (FR-002); single N2C
connection (FR-008, via #95); persisted-state atomicity (FR-003,
FR-016).
**Scale/Scope**: ~800 LoC new (300 in `Cardano.Node.Client.TxGenerator.*`,
~150 in `app/cardano-tx-generator/Main.hs`, ~100 for the wire,
~30–50 for #95's helper, plus tests).

## Constitution Check

Constitution: [memory/constitution.md](../../.specify/memory/constitution.md), v1.0.0.

| Principle | Status | Note |
|---|---|---|
| I. Channel-Driven N2C Clients | ✅ | Uses LSQChannel + LTxSChannel + ChainSync app, all over one mux session. |
| II. Devnet E2E Testing | ✅ | E2E suites against `withDevnet`, no node mocks. |
| III. Minimal Dependencies | ✅ | Only in-tree libs + already-pinned ledger / ouroboros. `cryptonite` is already a transitive dep; verify before pinning. |
| IV. Test Utilities Are First-Class | ⚠️ | `lib/Cardano/Node/Client/TxGenerator/*` is a library, not a test util. The new utilities (Population derivation, Snapshot percentiles) belong on the public surface so that future workloads can depend on them. ✅ once exposed in cabal. |
| Quality Gate: `just ci` | gating | Will run before every push. |
| Quality Gate: real devnet, no mocks | ✅ | E2E. |

No violations requiring entries in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```
specs/034-cardano-tx-generator/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── control-wire.md
├── checklists/
│   └── requirements.md
└── tasks.md            # produced by /speckit.tasks (next phase)
```

### Source code (repo root)

```
app/
└── cardano-tx-generator/
    └── Main.hs                  # CLI parsing + wiring + main loop

lib/Cardano/Node/Client/
├── N2C/
│   └── Connection.hs            # extend with `runNodeClientFull` (#95)
└── TxGenerator/
    ├── Population.hs            # deriveSignKey / deriveAddr; Network helpers
    ├── Selection.hs             # pickSource (StdGen-driven)
    ├── Fanout.hs                # pickDestinations + value sampling
    ├── Build.hs                 # TxBuild DSL composition (transact + refill)
    ├── Persist.hs               # master.seed / next-hd-index file IO
    ├── Snapshot.hs              # populationSize + percentile aggregation
    ├── Server.hs                # control-wire NDJSON server (Unix socket)
    └── Types.hs                 # Failure, request/response, Daemon record

cardano-node-clients.cabal       # add executable + new library modules

e2e-test/Cardano/Node/Client/E2E/
└── TxGeneratorSpec.hs           # hspec E2E (SC-001..SC-007 coverage)

test/Cardano/Node/Client/TxGenerator/
├── PopulationSpec.hs            # unit: derivation determinism
├── SelectionSpec.hs             # unit: viability + retry on StdGen
├── FanoutSpec.hs                # unit: value distribution shape
└── PersistSpec.hs               # unit: atomic write semantics
```

**Structure Decision**: single Haskell executable backed by a new
in-tree sub-library (`Cardano.Node.Client.TxGenerator.*`).
Re-uses the existing `lib/` directory; no new sub-library cabal
group. The combined N2C helper ([#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95))
lands in the existing `Cardano.Node.Client.N2C.Connection` module.

## Phase 0 — Outline & Research

See [research.md](research.md). Key decisions captured: D1 (embed
indexer via `Intersector`), D2 (one connection via #95 helper),
D3 (flat deterministic key derivation, not BIP32), D4 (PParams
queried once at startup), D5 (two-file persistence), D6 (in-memory
indexer in v1), D7 (NDJSON control wire), D8 (era pinned to
Conway), D9 (per-tx build shape: 1-input → K outputs + change),
D10 (per-request `mkStdGen seed`).

## Phase 1 — Design & Contracts

- [data-model.md](data-model.md) — entities, on-disk schema,
  in-process state shape, request/response Haskell types.
- [contracts/control-wire.md](contracts/control-wire.md) — NDJSON
  request/response schemas for `transact` / `refill` / `snapshot` /
  `ready` plus failure-category mapping for composer drivers.
- [quickstart.md](quickstart.md) — operator bring-up, drive
  example, replay-determinism check, restart-resilience check.
- Agent context: CLAUDE.md updated by `update-agent-context.sh`
  before commit.

## Phase 2 — Implementation order (preview; full breakdown in tasks.md)

1. **[#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95) helper** — `runNodeClientFull` in `N2C.Connection`. E2E
   smoke test that the three protocols negotiate together.
2. **Persist + Population** — pure modules, unit tests.
3. **Server skeleton** — control wire framing, `ready` and
   `snapshot`-against-empty-population responses; integration
   test without a relay.
4. **Indexer wiring** — embed `withInMemoryIndexer`, drive from
   `runNodeClientFull`'s ChainSync arm; ready becomes meaningful.
5. **Refill arm** — first wire of `Build` + `Selection.pickFaucet`,
   E2E against devnet (User Story 2).
6. **Transact arm** — `Selection.pickSource` + `Fanout` + `Build`
   for K-output tx; E2E covers User Story 1 + SC-001 + SC-002.
7. **Snapshot percentiles** — finalise; E2E covers User Story 3.
8. **Restart resilience** — verify SC-006 by killing the daemon
   mid-run inside an E2E test.

Each step is a vertical commit per the `pr` skill: types →
callers → tests in one commit each, bisect-safe, full quality
gate green before refresh.

## Status

**Completed**:
- 034-cardano-tx-generator branch on `origin`.
- Specify phase: [spec.md](spec.md) + [checklists/requirements.md](checklists/requirements.md).
- Plan phase: [research.md](research.md), [data-model.md](data-model.md),
  [contracts/control-wire.md](contracts/control-wire.md),
  [quickstart.md](quickstart.md), plan.md (this file).
- Two driving issues filed: [#84](https://github.com/lambdasistemi/cardano-node-clients/issues/84) (this work)
  and [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)
  (blocking N2C helper); both on the planner.
- Draft PR open: [#94](https://github.com/lambdasistemi/cardano-node-clients/pull/94).

**Current**: ready for `/speckit.tasks`.

**Blockers**:
- [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)'s helper
  is on this same branch, so it does not block the *PR* — it blocks
  the *commit ordering* inside the PR. Implementation step 1 lands
  the helper before everything else.

## Constitution Re-check (post Phase 1 design)

No new violations. Public exposure of `Cardano.Node.Client.TxGenerator.*`
keeps Principle IV satisfied.

## Complexity Tracking

No constitution violations; section intentionally empty.
