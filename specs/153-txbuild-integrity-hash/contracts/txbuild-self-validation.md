# Contract: TxBuild self-validation against ledger Phase-1

**Branch**: `153-txbuild-integrity-hash` | **Date**: 2026-05-15

The contract this PR commits to between TxBuild and any
caller (test or library or downstream tool).

---

## C-1 Return-type contract

`build` (and any equivalent public entry point) MUST
return either:

- `Right (Tx ConwayEra)` — a body that satisfies
  `applyTx pp utxo slot tx == Right _` where `pp` is the
  `PParams` value provided to the build call and `utxo`
  is the UTxO TxBuild used to assemble the body;
- or `Left (Check e)` — a check failure, where
  `LedgerFail (Phase1Rejected err)` carries the ledger's
  `ApplyTxError` verbatim.

There is no third case. A `Right body` whose
`script_integrity_hash` does not match the ledger's
computation is a contract violation and a release
blocker.

---

## C-2 PParams-identity contract

For a single `build` call:

- the `PParams` value used by the fee estimator,
- the `PParams` value used by the exec-units estimator,
- the `PParams` value used by
  `computeScriptIntegrity`,
- the `PParams` value used by the self-validation
  `applyTx` call,

MUST be `==`-equal. The design enforces this
structurally (one argument, optionally wrapped in
`PParamsBound`, per R-004).

---

## C-3 Integrity-hash contract

For any `Tx ConwayEra` returned by `build`:

- `body ^. scriptIntegrityHashTxBodyL == SNothing`
  if and only if the body has no redeemers and no
  witness-set datums.
- Otherwise, `body ^. scriptIntegrityHashTxBodyL ==
  SJust h` where `h` is computed over:
  - the redeemers exactly as serialized in the witness
    set (Conway map form, witness-set key `5`);
  - the set of language views for languages
    *referenced by the body's redeemers and
    reference-script inputs* (no language view for any
    language not so referenced);
  - the witness-set datums map (`TxDats` value, may
    be empty for inline-only datum txs);
  - keyed off the same `PParams` as C-2.

---

## C-4 Negative-build contract

If the caller's plan results in a body that fails
Phase-1, `build` returns:

```haskell
Left (LedgerFail (Phase1Rejected err))
```

where `err :: ApplyTxError ConwayEra` is the
unmodified value the ledger produced. TxBuild does
NOT pretty-print, classify, or otherwise mangle the
error before returning it — callers may pattern-match
on `err` for their own UX.

---

## C-5 Reproduction-fixture contract

The mainnet `swap-cancel` reproduction
(tx `84b2bb78f7f5dd2beb2830e8e6e88fd853a8f70ea73b161f0a0327de8c70146f`)
replayed offline through `build` against a captured
mainnet `PParams` snapshot MUST yield:

- `Right body`,
- with `body ^. scriptIntegrityHashTxBodyL`
  `== SJust 41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9`,
- and `applyTx pp utxo slot body == Right _`.

The test asserting this lives in `test/` and runs
under `just ci`.

---

## C-6 Downstream contract: no duplicate Phase-1 gates

After this PR lands, callers of `build` SHOULD NOT
add a second Phase-1 validation pass on the returned
body. The companion `amaru-treasury-tx` ticket
proposing such a gate is closed as superseded.

This is "SHOULD NOT" rather than "MUST NOT" because
nothing prevents a caller from re-running `applyTx`
on the returned body — it is simply redundant.

---

## C-7 Stability contract

C-1..C-5 are stable invariants of the `build` public
API. Any future change that weakens them — for
example, adding a "skip self-validation for
performance" flag — is a breaking change and requires
its own spec/PR.
