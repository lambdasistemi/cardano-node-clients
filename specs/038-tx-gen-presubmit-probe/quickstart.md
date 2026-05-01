# Quickstart: verifying the pre-submit probe end-to-end

**Branch**: `038-tx-gen-presubmit-probe`

## What this walks through

How a developer (or CI) verifies the new probe works after implementation,
in three layers from cheap to slow.

## 1. Unit test (seconds)

```bash
nix develop --quiet -c cabal test e2e-tests \
    --test-options='--match "verifyInputsUnspent"'
```

Drives `verifyInputsUnspent` against a stubbed `Provider`. Two cases:

- All requested inputs present in the stub's tip UTxO set → expect `True`.
- One input missing → expect `False`.

Lives in `test/Cardano/Node/Client/TxGenerator/SelectionSpec.hs` (or a new
`SubmitSpec.hs`). No node, no network.

## 2. E2E submit-idempotence test (~1 min)

```bash
nix develop --quiet -c cabal test e2e-tests \
    --test-options='--match "tx-generator submit idempotence"'
```

New file `e2e-test/Cardano/Node/Client/E2E/TxGeneratorSubmitIdempotenceSpec.hs`,
modeled on `TxGeneratorRestartSpec.hs`.

Shape:

1. `withRestartableCardanoNode` boots a devnet relay; daemon connects.
2. Drive a refill that lands a tx Tx1 spending faucet input X.
3. Force the daemon's submit primitive to raise `ConnectionLost` *after*
   Tx1 was accepted by the relay's mempool. (Implementation choice
   between (a) stop-then-restart relay between accept and round-trip,
   or (b) injected `LTxSChannel` wrapper that swallows `MsgAcceptTx` —
   pick the more reliable one in implement.)
4. Wait until Tx1 is included on the new chain.
5. Drive a second refill while the indexer's local view still reports X
   as unspent.
6. Assert:
   - The second refill returns `RefillFail IndexNotReady`.
   - No `submitTx` was invoked for the second refill (instrument via test
     hook on `Provider`).
   - No `ApplyTxErr "All inputs are spent. Transaction has probably already
     been included"` is observed.
   - Daemon is still alive and responsive.

## 3. Antithesis 1h run (full acceptance, ~1h wall, hours of compute)

Trigger via:

```
gh workflow run antithesis.yml -R cardano-foundation/cardano-node-antithesis \
  --ref <branch on PR #98 pinning this fix> \
  -f scenario=cardano_node_tx_generator -f duration_hours=1
```

Pass criteria (matches spec SC-001..SC-003):

- Antithesis report URL shows **0** `tx_generator_refill_submit_rejected`
  Always-assertion failures.
- Same report shows **0** `tx_generator_transact_submit_rejected`
  Always-assertion failures.
- Same report shows **≥3000** `Disconnected/Reconnecting` events at the
  supervisor (i.e. fault injection coverage unchanged).

Triage with the `antithesis-triage` skill if anything fails.

## Local quality gate

Before any push:

```bash
nix develop --quiet -c just ci
```

Runs build → e2e → cabal-fmt → fourmolu → hlint. Must be green before push.
