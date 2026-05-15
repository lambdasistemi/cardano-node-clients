# Research: TxBuild self-validates against ledger Phase-1

**Branch**: `153-txbuild-integrity-hash` | **Date**: 2026-05-15
**Plan**: [plan.md](./plan.md)

This file captures the open design questions that Phase 0
must resolve before implementation starts. Each entry is
Decision / Rationale / Alternatives, with the current
status (RESOLVED or OPEN). Anything OPEN must be closed
before the corresponding GREEN task in `tasks.md`.

---

## R-001: Which ledger function exposes Phase-1 validation?

**Status**: OPEN

**Question**: What is the right
`cardano-ledger-api`/`cardano-ledger-conway` entry point
for "Phase-1 validation only" — i.e. it must (a) include
the `script_integrity_hash` check, (b) include
fee/min-utxo/collateral checks, (c) not execute Plutus
scripts (Phase-2)?

**Candidates**:
- `Cardano.Ledger.Api.Tx.applyTx`
  — likely the full transition; pricey when scripts run.
- `Cardano.Ledger.Api.Tx.reapplyTx`
  — re-applies an already-validated tx; may skip
  Phase-1 in some shapes. Probably wrong.
- `Cardano.Ledger.Shelley.Rules.UTXOW`
  applied directly via `applyRuleByName` /
  `runRule` — gives the precise Phase-1 step but
  is lower-level.

**Acceptance**: chosen function, called from a test
fixture, returns `Left _` for the pre-fix
swap-cancel body and `Right _` for the post-fix
body. We measure roundtrip cost on a typical Conway
tx (target < 5 ms; if > 20 ms we re-evaluate).

**Alternatives considered**: writing a bespoke
Phase-1 reimplementation in `lib-tx-build`. Rejected
on FR-002 / constitution III grounds — we must not
ship a parallel ledger.

---

## R-002: Does `hashScriptIntegrity` already use Conway redeemer encoding?

**Status**: OPEN

**Question**: Conway witness-set redeemers are encoded
as a CBOR map (witness-set key `5`). The current
`lib-tx-build/.../Scripts.hs:84` uses
`Cardano.Ledger.Alonzo.Tx.hashScriptIntegrity`. Does
this function serialize redeemers consistently with
the Conway body's witness set, or does it still use
the pre-Conway array form?

**How we'll answer**: run `computeScriptIntegrity`
over the swap-cancel fixture's redeemers + cost-model
view at the pre-fix code, and compare the hash to
both (a) the body's value
(`03e9d7edc4e9b65b14a6076b19c7f13810292687b0c51b14c038ee4849f81941`)
and (b) the ledger's expected value
(`41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9`).
- If the current code reproduces the *body*'s wrong
  hash, the bug is in `hashScriptIntegrity`'s redeemer
  encoding for Conway → switch to Conway-era hash.
- If the current code reproduces neither, the bug is
  somewhere else (likely cost-model scope, R-003).

**Acceptance**: a passing assertion that the hash for
the issue-#153 fixture equals
`41a7cd57…dcf9`.

---

## R-003: Cost-models scope — single language or set?

**Status**: PARTIALLY OPEN

**Question**: The current
`computeScriptIntegrity :: Language -> PParams -> Redeemers -> …`
takes a single `Language` and folds in one
`LangDepView`. The ledger hashes the *set* of languages
referenced by redeemers in the body. If a tx uses only
PlutusV3 the existing API may or may not be correct in
practice — but it is fragile: the caller's chosen
`Language` is the source of truth, not the body.

**Decision (provisional)**: switch the API to derive
the language set from the body (specifically, the set
of script hashes resolved at each redeemer site and
each reference-script input). Caller can no longer
pass the wrong value.

**Rationale**: aligns with FR-001 "derived from the
body, not from caller convention" and removes a
recurring footgun.

**Alternatives considered**:
- Keep single `Language`, audit all three call sites.
  Rejected: same bug class will recur on the next
  mixed-language transaction.
- Derive from the resolved UTxO. Equivalent; either
  source yields the same answer for a well-formed
  body.

---

## R-004: `PParams` threading — does it need a newtype?

**Status**: OPEN

**Question**: Today, is `PParams ConwayEra` passed as
a regular argument through `draft` / `build` /
`finalize`? Or is it ever (a) re-fetched from a query
mid-build, (b) implicitly carried in a context that
could be replaced, (c) provided separately to the
balancer and to `computeScriptIntegrity`?

**How we'll answer**: read `TxBuild.hs` lines 1042,
1066, 1288, 1296, 1774, 1782 (the three integrity-hash
sites) plus `Balance.hs` 444, 569 (fee estimation),
and trace the `PParams` value back to the build entry
point. Note any divergence.

**Decision shape**:
- If `PParams` is already a single argument threaded
  through, no newtype is strictly required — a
  comment + an audit-style test suffices.
- If `PParams` is re-fetched or split, introduce a
  `PParamsBound era` newtype with smart constructor at
  the build entrypoint; pass `PParamsBound` to all
  four consumers (fee, exunits, integrity hash, self-
  validation). The wrapper is the "structurally
  impossible to mis-source" enforcement from FR-002.

**Acceptance**: every consumer of `PParams` in
`lib-tx-build` either takes `PParamsBound` or is
visibly downstream of a single `PParamsBound`
unwrap.

---

## R-005: Test PParams snapshot — reuse the staged file or take a fresh one?

**Status**: OPEN — needs user input.

**Question**: A 707-line `test/fixtures/pparams.json`
is already staged in `/code/cardano-node-clients`
(main repo, not committed) from a prior session.
Should we (a) pick it up and use it as the
swap-cancel reproduction's `PParams`, (b) capture a
fresh one specifically scoped to the issue-#153 slot,
or (c) both — keep the staged one as a general
fixture, capture a smaller scoped one for this test?

**Why we won't decide silently**: per repo memory
(`feedback_semantic_changes`, `feedback_investigate_bugs`)
absorbing an unknown staged file into this PR is
exactly the kind of cross-context drift we avoid.

**Action**: surface to user before tasks RED-1 runs.

---

## R-006: UTxO source for self-validation

**Status**: PARTIALLY OPEN

**Question**: `applyTx` needs the UTxO containing
every input the tx spends or references. What is the
UTxO value in scope at TxBuild's finalize point?

**Provisional answer**: the same `UTxO ConwayEra` the
balancer already used to resolve inputs and collateral
(seen near `Balance.hs:444` / `:569`). We do not
re-query; we pass that exact value.

**Open sub-question**: do reference inputs reside in
the same UTxO map, or are they passed separately? If
the latter, we need a step that constructs the
combined UTxO for `applyTx`.

**Acceptance**: a build path where `applyTx` is called
with exactly the inputs + reference inputs + collateral
that the body declares.

---

## Closing rule

When all entries above move to RESOLVED, this file
gets one final "Summary of decisions" section
listing the chosen ledger function name, the
chosen Conway hash function name, the chosen
language-derivation strategy, and the `PParamsBound`
decision. That summary is the input to
`/speckit.tasks`.
