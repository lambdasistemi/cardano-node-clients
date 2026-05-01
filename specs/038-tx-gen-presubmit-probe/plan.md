# Implementation Plan: Pre-submit chain-tip UTxO probe

**Branch**: `038-tx-gen-presubmit-probe` | **Date**: 2026-05-01
**Spec**: [spec.md](./spec.md)
**Tracks issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/111
**Builds on**: PR #105 (reconnect supervisor), PR #110 (freshness gate, spec 037)

## Status

- **Completed**: spec + quality checklist (commit b3b03a5).
- **Current**: planning artifacts.
- **Blockers**: none.

## Summary

Add one LSQ round-trip — a `GetUTxOByTxIn` query against the relay's current
tip — to the daemon's submit path. Both the refill arm and the transact arm
verify, immediately before calling the submit primitive, that every input
they are about to spend is still unspent on the chain they are submitting
to. On any input missing, return `IndexNotReady` (same response shape the
freshness gate established in PR #110) and let the composer retry on the
next tick. Closes the dominant residual duplicate-submit-after-reconnect
window where a `ConnectionLost`-triggered indeterminate submit may have
actually landed.

## Technical Context

| Item                  | Value                                                             |
| --------------------- | ----------------------------------------------------------------- |
| Language              | Haskell, GHC 9.6+                                                 |
| Primary deps (added)  | none — uses `ouroboros-network` `GetUTxOByTxIn` already imported  |
| Storage               | none (no persistence change)                                      |
| Testing               | hspec / cabal `e2e-tests` test suite                              |
| Target platform       | Linux (`nix develop`)                                             |
| Project type          | library + e2e test suite                                          |
| Performance goal      | ≤1 extra LSQ round-trip per submit attempt; no daemon throughput  |
|                       | regression in steady state (matches spec SC-005)                  |
| Constraints           | Must compose with freshness gate (FR-007); must not change wire   |
|                       | semantics on submit success (FR-005, FR-008)                      |
| Scale/scope           | one new Provider method; two daemon call sites; one new E2E spec  |

## Constitution Check

Constitution principles vs. this feature:

- **I. Channel-Driven N2C Clients**: extending `Provider` keeps the existing
  record-of-functions seam — no new mini-protocol, no direct ouroboros usage
  in the daemon. ✅
- **II. Devnet E2E Testing**: new spec runs against a real relay via
  `withRestartableCardanoNode`. No mocks at the wire layer. ✅
- **III. Minimal Dependencies**: zero new dependencies. ✅
- **IV. Test Utilities Are First-Class**: `verifyInputsUnspent` is a public
  helper from the same library; test stubs of `Provider` extend cleanly. ✅

**Quality gates** (`just ci`): build, e2e, cabal-fmt, fourmolu, hlint. No
violations expected.

**No constitutional violations** — Complexity Tracking section omitted.

## Project Structure

```text
specs/038-tx-gen-presubmit-probe/
├── plan.md             # this file
├── spec.md
├── research.md
├── data-model.md
├── contracts/
│   └── provider.md
├── quickstart.md
├── checklists/
│   └── requirements.md
└── tasks.md            # produced by speckit-tasks
```

### Source layout impact

```text
lib/Cardano/Node/Client/
├── Provider.hs                 # +1 record field: queryUTxOByTxIn
├── N2C/Provider.hs             # +1 implementation: queryUTxOByTxIn via LSQ
└── TxGenerator/
    ├── Daemon.hs               # +probe call in buildSignSubmit (refill)
    │                           # +probe call in transactWithSource (transact)
    └── Selection.hs            # +verifyInputsUnspent helper

e2e-test/Cardano/Node/Client/E2E/
└── TxGeneratorSubmitIdempotenceSpec.hs   # NEW

test/Cardano/Node/Client/TxGenerator/
└── SelectionSpec.hs            # +cases for verifyInputsUnspent
```

`cardano-node-clients.cabal` updates: register the new e2e module under the
`e2e-tests` test suite (currently line 295). Existing exposed-modules cover
`Provider`, `Selection`, `Daemon` — no library cabal change.

**Structure Decision**: existing single-project layout. The probe is a
layered addition: one Provider method, one helper, two call sites, two
tests. No new modules required at the library layer; one new test module.

## Phase plan (referenced by speckit-tasks)

The implementation phases below are mental anchors for tasks.md. Detailed
tasks come from `speckit-tasks`.

- **P0 — Provider extension**: add `queryUTxOByTxIn` to `Provider` record;
  implement in `N2C/Provider.hs`; extend any in-tree test stubs of
  `Provider` so the build still compiles.
- **P1 — Selection helper**: add `verifyInputsUnspent` in
  `TxGenerator/Selection.hs`; unit-test in `SelectionSpec.hs`.
- **P2 — Wire into refill arm**: insert probe call in `buildSignSubmit`
  between `addKeyWitness` and `submitTx`. Verify ConnectionLost path
  unchanged. Verify HD-index increment site unchanged.
- **P3 — Wire into transact arm**: same shape, in `transactWithSource`.
- **P4 — E2E spec**: `TxGeneratorSubmitIdempotenceSpec.hs` per
  `quickstart.md` step 2. Pick the `ConnectionLost`-injection mechanism
  (research D5 names two options; resolve in implement).
- **P5 — Cabal + CI**: register new test module; run `just ci`; iterate.

Each P is a single vertical commit per the workflow skill (one concern,
end-to-end, bisect-safe). Stack them via stgit.

## Risks

- **R1 — Probe race residual**: between probe success and submit, a
  competing tx may consume the input. Spec edge-case acknowledges this;
  acceptance is measured at the Antithesis run level, not zero-tolerance
  per-submit. If the residual rate is non-trivial, file a follow-up for
  in-flight tx-id tracking. **Mitigation**: monitor rate in the acceptance
  Antithesis run; do not fold tx-id tracking into this PR.
- **R2 — `ConnectionLost` injection in E2E (D5 option choice)**: stop-restart
  may be flaky depending on relay block production timing. **Mitigation**:
  if option A is flaky, switch to a deterministic `LTxSChannel` wrapper that
  swallows `MsgAcceptTx`. Decide in P4.
- **R3 — Provider stub fan-out**: every test that builds a `Provider` stub
  needs the new field. **Mitigation**: track during P0; if many call sites,
  introduce a `defaultProvider` smart constructor in test utilities.

## What's NOT in this plan

- In-flight tx-id tracking across reconnects (spec Assumption 3).
- Mempool-content awareness (spec Assumption 1).
- Composer-side assertion framing
  (https://github.com/cardano-foundation/cardano-node-antithesis/issues/107).
- Any change to the freshness gate from spec 037.
