# Quickstart: TxBuild self-validation

**Branch**: `153-txbuild-integrity-hash` | **Date**: 2026-05-15

How callers and test authors use the new TxBuild
contract after this PR lands.

---

## 1. Building a transaction (caller view)

Today (pre-fix):

```haskell
body <- build cfg plan
-- body may silently be Phase-1-invalid; we found out
-- only when the ledger rejected it on submission.
submit body
```

After this PR:

```haskell
result <- build cfg plan
case result of
  Right body            -> submit body            -- guaranteed Phase-1-valid
  Left (LedgerFail e)   -> reportPhase1 e         -- carries ledger's ApplyTxError
  Left (CustomFail e)   -> reportUser e
```

Where `reportPhase1`'s payload includes
`Phase1Rejected (ApplyTxError ConwayEra)` for the
new self-validation failure path. Existing
`LedgerFail` constructors
(`MinUtxoViolation`, `TxSizeExceeded`, …) continue
to be returned as before.

---

## 2. Reproducing the issue-#153 mainnet bug

Once the fixture lands in
`test/fixtures/mainnet-txbuild/swap-cancel-issue-153/`:

```haskell
-- in TxBuildSpec.hs (or a sibling file)
it "swap-cancel: computes the ledger's integrity hash" $ do
  pp   <- loadPParams "test/fixtures/pparams.json"
  utxo <- loadUtxo   "test/fixtures/mainnet-txbuild/swap-cancel-issue-153/utxo.json"
  plan <- loadPlan   "test/fixtures/mainnet-txbuild/swap-cancel-issue-153/plan.hs"
  Right body <- runBuild pp utxo plan
  body ^. scriptIntegrityHashTxBodyL
    `shouldBe` SJust expectedHash
  where
    expectedHash =
      ScriptIntegrityHash
        "41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9"
```

The same fixture also drives the Phase-1 assertion:

```haskell
it "swap-cancel: passes ledger Phase-1" $ do
  pp   <- loadPParams "test/fixtures/pparams.json"
  utxo <- loadUtxo   "test/fixtures/mainnet-txbuild/swap-cancel-issue-153/utxo.json"
  plan <- loadPlan   "test/fixtures/mainnet-txbuild/swap-cancel-issue-153/plan.hs"
  result <- runBuild pp utxo plan
  result `shouldSatisfy` isRight
  -- (implicitly: runBuild already ran applyTx and only
  -- returns Right after Phase-1 acceptance.)
```

---

## 3. Negative-build test recipe

To verify FR-007 (deliberately invalid plan ⇒ error,
not body):

```haskell
it "rejects a body the ledger would refuse" $ do
  pp   <- loadPParams "test/fixtures/pparams.json"
  utxo <- loadUtxo   "test/fixtures/mainnet-txbuild/swap-cancel-issue-153/utxo.json"
  -- Force a Phase-1 failure: pin the fee to zero
  -- (or use an artificial PParams with prohibitive
  -- maxTxSize). The exact knob falls out of R-001.
  result <- runBuild pp utxo (forceInvalid plan)
  result `shouldBe` Left (LedgerFail (Phase1Rejected someErr))
```

The body is never returned in this case.

---

## 4. What changes for downstream tools

Tools that today call `build` and then re-run their
own Phase-1 gate (`amaru-treasury-tx`'s companion
ticket, any future consumer) can simply drop that
gate. The build result is already validated.

A grep recipe to verify there are no stale gates:

```bash
# Run against amaru-treasury-tx and any other consumer
git grep -nE 'applyTx|reapplyTx|Phase1' -- '*.hs'
```

The expected result is "no post-build invocations of
ledger validation on the TxBuild output".

---

## 5. Running it

Standard:

```bash
nix develop --quiet -c just ci
```

The new test cases run under the existing `lib-tx-build`
test suite and require no new external setup.
