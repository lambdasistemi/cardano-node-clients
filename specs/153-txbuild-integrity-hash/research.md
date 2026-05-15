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

**Status**: RESOLVED (2026-05-15)

**Decision**: `Cardano.Ledger.Api.Tx.applyTx` from
`cardano-ledger-api` (pinned to `1.13.0.0` in
`cabal.project` line 68). It performs the full UTXOW
transition, which includes the
`script_integrity_hash` check, fee / min-utxo /
collateral checks, and witness completeness; under
Phase-1 it does **not** execute Plutus scripts —
script evaluation happens in a separate Phase-2
function. This is the entry point the plan calls
out and the one already used by the wider ecosystem
for offline tx validation.

**Rationale**: it is the smallest API surface that
fully matches FR-003 ("ledger Phase-1 on its own
output"), already in the closure, and behaves the
same way as the node at submission time.

**Alternatives considered**:
- `reapplyTx` — re-applies an already-validated tx;
  may skip checks we care about. Rejected.
- `Cardano.Ledger.Shelley.Rules.UTXOW` via
  `applyRuleByName` / `runRule` — lower-level,
  same semantics but more boilerplate. Rejected.
- A bespoke Phase-1 reimplementation in
  `lib-tx-build` — rejected on FR-002 / constitution
  III grounds (no parallel ledger).

**Caveat**: the exact type signature of
`applyTx 1.13.0.0` is verified empirically at T011
when we first call it from a test. If the signature
forces a wrapper, the wrapper lives in
`lib-tx-build` and exposes the simpler shape
`applyTxBody :: PParamsBound era -> UTxO era ->
SlotNo -> Tx era -> Either (ApplyTxError era) ()`.

---

## R-002: Does `hashScriptIntegrity` already use Conway redeemer encoding?

**Status**: DEFERRED (decision rule recorded; empirical
verification happens at T011).

**Decision rule**: we keep
`Cardano.Ledger.Alonzo.Tx.hashScriptIntegrity` for now —
the `Redeemers ConwayEra` value's `EncCBOR` instance is
era-parameterized and is expected to produce the
Conway map form (witness-set key `5`). The first RED
test (T011) computes the hash for the issue-#153
fixture and compares it to the ledger's expected value
`41a7cd57…dcf9`.

- If the result matches → the existing
  `hashScriptIntegrity` is correct for Conway; the bug
  is purely in the cost-models / language-set scope
  (R-003). No change to `hashScriptIntegrity` itself.
- If the result differs → the encoding bug is real;
  switch to the Conway-era equivalent
  (`Cardano.Ledger.Conway.Tx.hashScriptIntegrity` if
  it exists, or a re-export from
  `Cardano.Ledger.Api`).

**Rationale for deferring**: the source for
`cardano-ledger-alonzo 1.15.0.0` is not in the
worktree closure; an empirical golden-vector check
is cheaper and more reliable than reading the ledger
source through cabal. The check is required anyway
(SC-002), so this is a no-cost deferral.

**Acceptance**: T011 (the RED test for the mainnet
reproduction) computes the hash and compares it to
`41a7cd57…dcf9`. The R-002 outcome is encoded in
whether T016 needs to change `hashScriptIntegrity`'s
import or not.

---

## R-003: Cost-models scope — single language or set?

**Status**: RESOLVED (2026-05-15)

**Question**: The current
`computeScriptIntegrity :: Language -> PParams -> Redeemers -> …`
takes a single `Language` and folds in one
`LangDepView`. The ledger hashes the *set* of languages
referenced by redeemers in the body. If a tx uses only
PlutusV3 the existing API may or may not be correct in
practice — but it is fragile: the caller's chosen
`Language` is the source of truth, not the body.

**Decision**: switch the API to derive the language
set from the body (specifically, the set of script
hashes resolved at each redeemer site and each
reference-script input). Caller can no longer pass
the wrong value.

**Confirmed by source reading**: all three call
sites in `lib-tx-build/Cardano/Node/Client/TxBuild.hs`
(lines 1043, 1289, 1775) currently hardcode the
literal `PlutusV3`. Caller convention is the only
guarantee today — exactly the footgun this
re-scopes away.

**Helper signature**: per
[data-model.md](./data-model.md) E-3,

```haskell
languagesUsedInBody
  :: TxBody ConwayEra
  -> UTxO ConwayEra
  -> Set Language
```

Walks (a) the body's spending redeemers and their
resolved scripts, (b) reference-script inputs that
supply a Plutus script. Native (timelock) scripts
do not contribute. All inputs available at every
existing call site (`inputUtxos` + `refUtxos`).

**Rationale**: aligns with FR-001 "derived from the
body, not from caller convention" and removes a
recurring footgun. Implementable from data already
in scope; no new query.

**Alternatives considered**:
- Keep single `Language`, audit all three call sites.
  Rejected: same bug class will recur on the next
  mixed-language transaction.
- Derive from the resolved UTxO instead of the body.
  Equivalent; either source yields the same answer
  for a well-formed body. Body-derived chosen
  because it keeps the helper independent of any
  enclosing UTxO map's completeness.

---

## R-004: `PParams` threading — does it need a newtype?

**Status**: RESOLVED (2026-05-15, user decision)

**Decision**: introduce `PParamsBound era` per
[data-model.md](./data-model.md) E-1. Smart
constructor at the build entrypoint; every internal
helper that depends on protocol parameters takes
`PParamsBound era` instead of `PParams era`.

**Rationale**: a structural guarantee is preferred
over a behavioral one even if today's flow happens
to be single-instance. The newtype is ~10 lines, the
API surface change is internal-only (callers still
pass `PParams era` to the build entry point and the
wrapper is constructed inside), and it eliminates
the entire "PParams source drift" failure mode at
the type level, which is the FR-002 contract.

**Acceptance**: every reference to `PParams` inside
`lib-tx-build`'s build path either takes
`PParamsBound era` or is visibly the single
`unPParamsBound` unwrap at a leaf consumer
(`estimateMinFeeTx`, the ledger Phase-1 call) where
the underlying ledger API still demands raw
`PParams`.

---

## R-005: Test PParams snapshot — reuse the staged file or take a fresh one?

**Status**: RESOLVED (2026-05-15, user decision)

**Decision**: recapture a fresh `pparams.json`
scoped to the issue-#153 slot. Ignore the 707-line
file staged in `/code/cardano-node-clients` from a
prior session — it stays untouched, and that worktree
remains the user's to dispose of.

**Acceptance**: T009 captures mainnet PParams at the
epoch active when tx
`84b2bb78f7f5dd2beb2830e8e6e88fd853a8f70ea73b161f0a0327de8c70146f`
was rejected, writes them to
`test/fixtures/pparams.json` of this worktree, and
commits the file alongside the swap-cancel fixture.

**Mechanism**: this project's own LSQ client
against a mainnet node socket — the same code path
`cardano-node-clients` ships for protocol-parameter
queries. Concretely either (a) a small one-off
program in the worktree that opens
`LSQChannel`, issues `GetCurrentPParams`, and dumps
the result as JSON, or (b)
`cardano-cli query protocol-parameters --mainnet
--socket-path …`, which is the same Ouroboros LSQ
query underneath. Either source is the ledger's own
form — no Blockfrost, no third-party service, no
external API dependency in the test fixture.

Memory `feedback_fix_own_tools`: the project is the
N2C client toolkit; using anything else to capture
PParams *for this project's tests* would be the
wrong direction.

---

## R-006: UTxO source for self-validation

**Status**: RESOLVED (2026-05-15)

**Decision**: build the `UTxO ConwayEra` argument to
`applyTx` as the union of three lists already in
scope at the return point of `buildWith` in
`lib-tx-build/Cardano/Node/Client/TxBuild.hs`:
`inputUtxos`, `boCollateralUtxos opts`, and
`refUtxos`. No new query is required.

**Confirmed by source reading**:
`lib-tx-build/Cardano/Node/Client/TxBuild.hs` lines
1245–1246, 1250 (the three UTxO lists arrive at
`buildWith` as parameters); lines 1309–1316
(`balanceTxWith` is called with all three); lines
1515 and 1569 (the final balanced tx is returned
while all three lists remain in lexical scope).
`lib-tx-build/Cardano/Node/Client/Balance.hs` lines
206–224 (signature of `balanceTxWith` taking all
three UTxO sources separately).

**Combined-UTxO helper**: introduce a small
`combinedUtxo :: [(TxIn, TxOut era)] -> [(TxIn, TxOut era)]
-> [(TxIn, TxOut era)] -> UTxO era` (or inline at the
call site) that folds the three lists into a single
`Map TxIn (TxOut era)` and wraps it in `UTxO`. It is
the caller of `applyTx`, not part of the public API.

**Acceptance**: the `applyTx` call site at finalize
time consumes exactly the inputs + reference inputs +
collateral that the body declares. T018 verifies this
by passing a body whose collateral references a
UTxO outside the union and observing the resulting
`UtxoFailure` is surfaced.

---

## Closing rule

When all entries above move to RESOLVED, this file
gets one final "Summary of decisions" section
listing the chosen ledger function name, the
chosen Conway hash function name, the chosen
language-derivation strategy, and the `PParamsBound`
decision. That summary is the input to
`/speckit.tasks`.

---

## Summary of decisions (2026-05-15)

| ID | Decision |
|----|----------|
| R-001 | Phase-1 entry point = `Cardano.Ledger.Api.Tx.applyTx` from `cardano-ledger-api 1.13.0.0`. Signature verified empirically at T011; wrapper added in `lib-tx-build` if needed. |
| R-002 | Keep `Cardano.Ledger.Alonzo.Tx.hashScriptIntegrity`; rely on `Redeemers ConwayEra`'s era-parameterized encoding to produce the Conway map. T011 golden-vector check decides whether a Conway-specific replacement is needed. |
| R-003 | Body-derived `Set Language` via `languagesUsedInBody :: TxBody ConwayEra -> UTxO ConwayEra -> Set Language`. Replaces the literal `PlutusV3` hardcoded at TxBuild.hs:1043,1289,1775. |
| R-004 | Add `PParamsBound era` newtype per [data-model.md](./data-model.md) E-1. Smart constructor at the build entrypoint; all internal helpers consume `PParamsBound era`. |
| R-005 | Recapture a fresh mainnet `pparams.json` scoped to issue #153's epoch via this project's own LSQ client (`GetCurrentPParams`) or `cardano-cli query protocol-parameters --mainnet`. **No Blockfrost / external service.** Staged file in `/code/cardano-node-clients` (main repo) is ignored. |
| R-006 | `UTxO ConwayEra` for `applyTx` = union of `inputUtxos ∪ boCollateralUtxos opts ∪ refUtxos` already in scope at `buildWith` (lines 1245–1316). No new query. |

These are the inputs to `/speckit.tasks`.
