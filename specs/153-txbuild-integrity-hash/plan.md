# Implementation Plan: TxBuild self-validates against ledger Phase-1

**Branch**: `153-txbuild-integrity-hash` | **Date**: 2026-05-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/153-txbuild-integrity-hash/spec.md`

## Summary

Make the ledger's Phase-1 application function (`applyTx` /
`Cardano.Ledger.Api.Tx.applyTx`-equivalent from
`cardano-ledger-api`) a mandatory step inside TxBuild's
build/finalize path. The same `PParams` value drives fee
estimation, exec-units, integrity-hash computation, and the
self-validation step — threaded structurally as a single
argument, never re-fetched. The existing
`script_integrity_hash` divergence is fixed as one instance
the new gate catches.

Bug-level technical approach for the integrity hash itself:

- `computeScriptIntegrity` currently takes a single
  `Language` and a `Redeemers ConwayEra` and folds in one
  `LangDepView`. The Conway witness set serializes
  redeemers as a map; verify `hashScriptIntegrity` from
  `Cardano.Ledger.Alonzo.Tx` follows the body's CBOR
  serialization (Conway map form, witness-set key `5`).
  If it does not, switch to the Conway-era
  `hashScriptIntegrity` (or equivalent) from
  `Cardano.Ledger.Conway`/`Cardano.Ledger.Api`.
- Replace the single-`Language` argument with the
  *set* of languages actually referenced by redeemers
  in the body, derived from the body itself — never
  from caller convention.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.2 (matches existing
flake-pinned toolchain).
**Primary Dependencies**:
- `cardano-ledger-conway` (1.21) — already in closure.
- `cardano-ledger-alonzo` — `hashScriptIntegrity`,
  `ScriptIntegrity`, `LangDepView`, `getLanguageView`.
- `cardano-ledger-api` — `applyTx` (or equivalent
  Phase-1 functional path) for self-validation.
- `cardano-ledger-core` — `PParams`, `ApplyTxError`.
- All already pulled in by `lib-tx-build`'s cabal file;
  no new `source-repository-package` entries expected.
**Storage**: N/A. TxBuild is a pure assembly layer.
**Testing**: `hspec` + `tasty`-style golden, as in the rest
of the suite. New tests live in
`test/Cardano/Node/Client/TxBuildSpec.hs` (the property/
golden home for tx-builder tests) and a new fixture-driven
spec in `test/Cardano/Node/Client/Scripts*Spec.hs` if the
existing files don't fit.
**Target Platform**: Linux x86_64 (same as repo CI).
**Project Type**: Haskell library (`lib-tx-build`).
**Performance Goals**: One additional `applyTx` call per
TxBuild build (a few ms against an in-memory UTxO). Not a
hot path; well within `just ci` budget.
**Constraints**:
- Same `PParams` instance threaded through the whole build
  call. Structural, not by convention — single argument.
- Self-validation runs against the UTxO TxBuild already has
  in scope; no new network query.
- Failure must surface the ledger's `ApplyTxError` faithfully
  to the caller.
**Scale/Scope**: Roughly two modules touched
(`TxBuild.hs`, `Scripts.hs`), one or two new test specs,
plus golden fixtures for the mainnet reproduction.

## Constitution Check

Pulled from
`/code/cardano-node-clients-issue-153/.specify/memory/constitution.md`.

| Principle | Status | Notes |
|---|---|---|
| I. Channel-Driven N2C Clients | N/A | This is the pure tx-build layer; no Ouroboros channels involved. |
| II. Devnet E2E Testing | PASS | The mainnet-reproduction test is a fixture-driven check using a captured `PParams` snapshot + a captured `UTxO`. The negative test (FR-007) is also fixture-driven. No mocks for the ledger — we call the real ledger functional API. An E2E spec under `test/Cardano/Node/Client/E2E/TxBuildSpec.hs` can also exercise self-validation end-to-end against `withCardanoNode` if desired (stretch, not required by spec). |
| III. Minimal Dependencies | PASS | All deps already in closure. Adds no application-specific types. |
| IV. Test Utilities Are First-Class | PASS | Reusable helper (e.g. `applyTxBody :: PParams -> UTxO -> Slot -> Tx -> Either ApplyTxError ()`) lands in `lib-tx-build` so downstream tests can use the same gate to assert tx-bodies they construct elsewhere are also Phase-1-valid. |
| Quality Gates: `just ci` passes | PASS | New tests must run under `just ci`; no new external setup. |
| Quality Gates: real devnet for E2E | PASS | Untouched. |
| Quality Gates: no mocks for node | PASS | Untouched. |
| Workflow: Nix-first, Fourmolu, rebase | PASS | Standard. |

No violations; Complexity Tracking section is empty.

## Project Structure

### Documentation (this feature)

```text
specs/153-txbuild-integrity-hash/
├── plan.md                       # This file
├── spec.md
├── checklists/
│   └── requirements.md
├── research.md                   # Phase 0 output
├── data-model.md                 # Phase 1 output
├── quickstart.md                 # Phase 1 output
├── contracts/                    # Phase 1 output
│   └── txbuild-self-validation.md
└── tasks.md                      # /speckit.tasks output
```

### Source Code (repository root)

```text
lib-tx-build/Cardano/Node/Client/
├── TxBuild.hs        # Build/finalize path; integrate Phase-1 self-validation
│                     # at the return point. Thread the single PParams arg.
├── Scripts.hs        # Fix `computeScriptIntegrity`: accept Set Language
│                     # derived from the body, use the Conway-era
│                     # hashScriptIntegrity if needed.
├── Balance.hs        # PParams already lives here for fee estimation;
│                     # confirm it's the same value passed to the new
│                     # self-validation step.
├── Inputs.hs / Witnesses.hs / Deposits.hs / Credentials.hs / Ledger.hs
│                     # Likely untouched; check that no PParams source
│                     # is re-fetched here.

test/Cardano/Node/Client/
├── TxBuildSpec.hs           # Add golden tests for self-validation
│                            # (positive + negative + mainnet repro).
├── TxBuildGoldenSpec.hs     # Possibly: add the mainnet swap-cancel
│                            # vector if it fits the golden style.
├── ScriptsSpec.hs           # NEW (if needed): focused integrity-hash
│                            # tests over Conway redeemers + mixed langs.
test/fixtures/
├── pparams.json             # Mainnet PParams snapshot for the
│                            # swap-cancel reproduction
│                            # (NOTE: a 707-line `pparams.json` is
│                            # already staged in the main repo from a
│                            # prior session — confirm with user before
│                            # picking up vs starting fresh).
└── mainnet-txbuild/
    └── swap-cancel-issue-153/  # NEW fixture dir for the reproduction
        ├── utxo.json
        ├── plan.json or .hs    # The exact TxBuild plan
        └── expected-body.cbor.hex
```

**Structure Decision**: stay within the existing
`lib-tx-build` Haskell library layout. No new module
directories. Self-validation is exposed as a small public
helper (so consumers can use it too if they ever construct
bodies by hand), but the build/finalize path calls it
unconditionally.

## Phase 0: Outline & Research

Open questions to resolve before writing code. Each one
gets a Decision / Rationale / Alternatives entry in
`research.md`.

1. **Ledger Phase-1 API choice.** Which exact function
   from `cardano-ledger-api` (or `cardano-ledger-conway`)
   represents "Phase-1 validation that includes
   `script_integrity_hash` check but excludes Plutus script
   execution"? Candidates:
   - `Cardano.Ledger.Api.Tx.applyTx` — full transition
     (Phase-1 + Phase-2 trigger).
   - A reapplication function that skips script execution.
   - A `Cardano.Ledger.Shelley.Rules.UTXOW`-style rule
     applied directly.
   The pick must (a) include script-integrity-hash check
   and (b) be cheap enough for every build.

2. **Conway redeemers form.** Does
   `Cardano.Ledger.Alonzo.Tx.hashScriptIntegrity` already
   serialize redeemers as the Conway map (witness-set key
   `5`)? If not, identify the Conway-era replacement.
   Empirically: hash the issue-#153 fixture with current
   code, compare to the ledger's expected
   `41a7cd57…dcf9`.

3. **`PParams` single-instance threading.** Audit
   `TxBuild.hs` and `Balance.hs`: is `PParams` already a
   single argument passed straight through, or is it
   re-fetched / mutated at any point in
   `draft`/`build`/`finalize`? Document the actual flow
   in research, then decide whether a refactor is
   required to satisfy FR-002 ("structurally
   impossible to mis-source"). The cheapest fix may be
   to add a newtype wrapper that can only be constructed
   at the build entrypoint.

4. **Self-validation UTxO source.** What UTxO is in scope
   at the build/finalize point? The same `UTxO` the
   balancer used to assemble inputs and collateral.
   Confirm we can hand it to `applyTx` without
   re-querying.

5. **Test pparams snapshot.** Reuse the staged
   `test/fixtures/pparams.json` already present in
   `/code/cardano-node-clients` (main repo), or take a
   fresh snapshot scoped to the issue-#153 reproduction?
   Flag for user decision in Phase 0 output; do not
   silently absorb the staged file (per
   `feedback_investigate_bugs` / `feedback_semantic_changes`).

**Output**: `research.md` with answers, links to
ledger-api Haddock pages, and a short note on each
alternative considered.

## Phase 1: Design & Contracts

**Prerequisites**: `research.md` complete.

### Data model

`data-model.md` will describe two small additions:

- `PParamsBound era` (newtype or smart constructor)
  — wraps `PParams era` so that all four consumers
  inside TxBuild (fees / exunits / integrity-hash /
  self-validation) take the wrapped value, and the
  wrapper can only be built at the build entrypoint.
  Implements FR-002 structurally.
- Extend (or replace) `LedgerCheck` so that
  `Phase1Rejected ApplyTxError` is a constructor.
  The existing closed enum
  (`MinUtxoViolation`, `TxSizeExceeded`,
  `ValueNotConserved`, `CollateralInsufficient`)
  becomes a subset of what Phase-1 catches; some of
  those may be subsumed by `applyTx` and can be
  retired in a follow-up (NOT in this PR — scope
  discipline).

### Contracts

`contracts/txbuild-self-validation.md` will spell out the
new TxBuild invariants:

- *Pre-return contract:* on every successful build call,
  the body returned has passed
  `applyTx pparams utxo slot tx == Right _`, where
  `pparams` is the same value provided to the build
  call.
- *Failure contract:* a body that fails Phase-1 is never
  returned; instead the caller receives the
  `ApplyTxError` from the ledger, wrapped in
  `LedgerFail (Phase1Rejected …)`.
- *Hash contract:* for any tx with redeemers,
  `script_integrity_hash` is computed from (a) the
  redeemers exactly as they appear in the witness set
  in Conway map form, (b) the set of language views for
  the Plutus versions actually referenced by those
  redeemers (derived from the body, not from caller),
  (c) the witness-set datums map (empty when only inline
  datums are used), all keyed off the same
  `PParamsBound`.

### Quickstart

`quickstart.md` will show the minimal caller usage:

```haskell
-- before this PR
body <- build cfg plan        -- may silently produce invalid body

-- after this PR
result <- build cfg plan
case result of
  Right body            -> submit body
  Left (LedgerFail e)   -> reportPhase1 e
  Left (CustomFail e)   -> reportUser e
```

And the negative-test recipe (deliberately invalid plan
→ assert `Left (LedgerFail (Phase1Rejected _))`).

### Agent context update

Run `./.specify/scripts/bash/update-agent-context.sh
--agent claude` after Phase 1 so `CLAUDE.md` picks up
the new feature row (153-txbuild-integrity-hash).

**Outputs**: `data-model.md`, `contracts/txbuild-self-validation.md`,
`quickstart.md`, `CLAUDE.md` updated.

## Phase 2: Tasks (preview — generated by /speckit.tasks)

Sketch only, not a substitute for `tasks.md`:

1. (RED) Add the mainnet-#153 reproduction fixture under
   `test/fixtures/mainnet-txbuild/swap-cancel-issue-153/`
   + a failing golden in `TxBuildSpec.hs` asserting
   computed `script_integrity_hash` ==
   `41a7cd57…dcf9`. Watch it fail.
2. (RED) Add a negative-build property test (e.g.
   artificially zero the fee) asserting the build
   returns `Left (LedgerFail (Phase1Rejected _))`.
   Watch it fail because no self-validation step
   exists yet.
3. (GREEN, hash) Fix `Scripts.computeScriptIntegrity`
   per Phase 0 finding (Conway-form redeemers, Set of
   languages derived from body). Make test 1 pass.
4. (GREEN, validation) Add the `applyTx` self-validation
   step to TxBuild's finalize path; thread `PParamsBound`
   structurally. Make test 2 pass.
5. (REFACTOR) Adjust callers of `computeScriptIntegrity`
   inside `TxBuild.hs` to feed the body-derived language
   set (three call sites).
6. (POLISH) Update `lib-tx-build` Haddock and module
   header for `Scripts.hs` to describe the new contract.
   Update `quickstart.md`.
7. (DOWNSTREAM) On a separate branch in
   `lambdasistemi/amaru-treasury-tx`, remove any
   post-build Phase-1 gate (or close the companion ticket
   if it never landed) — referenced by the PR body, but
   *not* a code change in this PR.
8. Final `just ci`; squash-fix where needed for vertical
   commits.

## Complexity Tracking

No constitution violations; section intentionally empty.
