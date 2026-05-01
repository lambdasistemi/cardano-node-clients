# Implementation Plan: Gate tx-generator arms on indexer freshness after N2C reconnect

**Branch**: `037-tx-gen-indexer-fresh` | **Date**: 2026-05-01 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/037-tx-gen-indexer-fresh/spec.md`

## Summary

Add a single boolean gate, `rsIndexFresh`, to `ReadyState` in `lib/Cardano/Node/Client/TxGenerator/Daemon.hs`. The supervisor's `setUpstreamStatus UpstreamConnected` call site (Daemon.hs:322) clears it; the chain-sync follower's `rollForward` callback in `mkFollower` (Daemon.hs:1062, via `updateReady`) sets it. The two top-of-arm wrappers `doRefill` and `doTransact` (Daemon.hs:399, 419) read it and short-circuit with `RefillFail IndexNotReady` / `TransactFail IndexNotReady` — vocabulary already on the wire (Types.hs:136, 146). No new failure reason, no new wire message, no composer-side change for retry behaviour. Threshold bumps for `tx_generator_*_landed` Sometimes-assertions live in the companion `cardano-foundation/cardano-node-antithesis` repo and are tracked there.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches repo)
**Primary Dependencies**: `cardano-ledger-conway`, `ouroboros-network`, internal `chain-follower` `Follower` abstraction, internal `N2C.Reconnect.runReconnectLoop` (PR #105)
**Storage**: in-memory `TVar ReadyState` (no persistence change)
**Testing**: `hspec` E2E (`cabal test e2e-tests` via `just e2e`), driven against a real devnet node spun up by `withCardanoNode`
**Target Platform**: Linux daemon (`cardano-tx-generator` executable)
**Project Type**: single-project Haskell library + executables
**Performance Goals**: zero added overhead in the steady state (one extra `Bool` read per arm tick); arms must remain non-blocking on the freshness check (no STM retry, just a snapshot read)
**Constraints**: must NOT change wire protocol or NDJSON shape; must NOT alter chain-sync streaming semantics; must compose cleanly with existing `rsReady` gate
**Scale/Scope**: ~30 LoC behaviour change in `Daemon.hs`; one new field on `ReadyState`; one new E2E spec covering the freshness window; threshold bumps in the companion antithesis repo are out of scope here

## Constitution Check

Ratified principles (constitution.md @ v1.0.0):

- **I. Channel-Driven N2C Clients** — PASS. No new mini-protocol, no new channel. The gate is a local read of an existing `TVar` populated by the existing chain-sync `Follower` and reconnect supervisor.
- **II. Devnet E2E Testing** — PASS. The fix's primary test is an E2E spec that drives `setUpstreamStatus` via the supervisor and observes arm responses against a real devnet relay.
- **III. Minimal Dependencies** — PASS. No new dependencies. One new boolean field on an existing record.
- **IV. Test Utilities Are First-Class** — PASS. Reuses the devnet harness verbatim. If a new helper is needed for "force a reconnect" deterministically, it goes into the existing `devnet` library, not a new package.

Quality gates (`just ci` passes, all E2E against a real devnet node, no mocks): preserved.

No violations.

## Project Structure

### Documentation (this feature)

```text
specs/037-tx-gen-indexer-fresh/
├── plan.md              # This file
├── spec.md
├── research.md          # Design decisions for the gate
├── data-model.md        # ReadyState extension + state diagram
├── quickstart.md        # How to run the new E2E spec locally
├── contracts/
│   └── arm-gate.md      # The arm-side contract: when each arm short-circuits
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit.specify)
└── tasks.md             # Phase 2 output — produced by /speckit.tasks
```

### Source Code (repository root)

```text
lib/Cardano/Node/Client/
├── N2C/
│   └── Reconnect.hs                  # (no change)
└── TxGenerator/
    ├── Daemon.hs                     # CHANGED: rsIndexFresh field, setUpstreamStatus
    │                                 # clears it, updateReady sets it, doRefill/doTransact
    │                                 # short-circuit on it
    ├── Types.hs                      # NO CHANGE — IndexNotReady reason already exists
    └── Server.hs                     # NO CHANGE — wire shape unchanged

test/Cardano/Node/Client/E2E/
└── TxGeneratorIndexFreshSpec.hs      # NEW: post-reconnect freshness E2E

test/Cardano/Node/Client/TxGenerator/
└── DaemonFreshGateSpec.hs            # NEW (optional — pure unit test of the
                                      # ReadyState transition function if extracted;
                                      # may be folded into existing ServerSpec)
```

**Structure Decision**: Single-project layout (Option 1). The change is fully contained inside the `cardano-tx-generator` executable's daemon module. No layer split, no new crate, no API addition. The companion threshold-bump PR lives in a different repository (`cardano-foundation/cardano-node-antithesis`) and is tracked there, not here.

## Complexity Tracking

> No constitutional violations to justify. Section retained per template.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none)    |            |                                      |
