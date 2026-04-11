# Tasks: Transaction Builder DSL

**Branch**: `003-tx-builder-dsl`
**Updated**: 2026-04-11
**Spec**: [spec-design.md](spec-design.md)

Each slice is one commit: types + logic + interpreter + test.

---

## Slice 1: Simple pub-key spend + draft

GADT with `Spend`, `Send`, `Collateral`, `Peek`. Types: `Convergence`, `Check`, `LedgerCheck`, `SpendWitness`, `Interpret`, `InterpretIO`. Smart constructors: `spend` (returns `Word32` via `Peek`), `payTo`, `collateral`. `draft` interpreter (pure, `q = Void, e = Void`).

**Test**: simple transfer — verify inputs/outputs in assembled Tx, `spend` returns correct index.

**Depends**: none

---

## Slice 2: Script spend + mint + redeemer indices

Add `MintI`, `AttachScript`, `ReqSignature` to GADT. `MintWitness` existential. Smart constructors: `spendScript`, `mint`, `attachScript`, `requireSignature`. `draft` computes spending + minting redeemer indices automatically.

**Test**: Boot-shaped tx (spend + mint +1), End-shaped tx (spend + mint -1 + dual redeemers). Verify redeemer indices match sorted position.

**Depends**: Slice 1

---

## Slice 3: Peek convergence + build loop

`build` interpreter: fixpoint iteration over `Peek` nodes, script evaluation via evaluator function, ExUnits patching, recompute integrity hash, fee balancing via `balanceTx`. Convergence: iterate while any `Peek` returns `Iterate`, stop when all `Ok` and Tx body stable.

**Test**: fee-dependent outputs — refund = totalIn - fee - tips. Verify `Peek` reads fee, outputs converge in 2-3 iterations. (Conservation case from cardano-mpfs-onchain#37.)

**Depends**: Slice 2

---

## Slice 4: Ctx + pluggable queries

Add `Ctx` instruction. `ctx` smart constructor. `build` takes `InterpretIO q`. `draftWith` takes `Interpret q` (or `DMap q Identity`).

**Test**: define `data TestQ a where GetValue :: TestQ Int`. Use `ctx GetValue` in a builder, interpret with `Interpret TestQ`. Verify the value flows through bind into a subsequent step.

**Depends**: Slice 3

---

## Slice 5: Valid + library checkers

Add `Valid` instruction. `valid` smart constructor. `Check e = Pass | LedgerFail LedgerCheck | CustomFail e`. Library checkers: `checkMinUtxo`, `checkTxSize`. Interpreter runs checks after `Peek` convergence. `build` returns `Left (ChecksFailed [Check e])` on failure.

**Test**: output below min UTxO → `LedgerFail (MinUtxoViolation ...)`. Custom check → `CustomFail MyErr`. All-pass → `Right tx`.

**Depends**: Slice 3

---

## Slice 6: Reference inputs + validity intervals

Add `Reference`, `SetValidFrom`, `SetValidTo`. Smart constructors: `reference`, `validFrom`, `validTo`.

**Test**: Retract-shaped tx — reference input (not consumed), validity window (lower + upper), required signer. Verify fields in assembled TxBody.

**Depends**: Slice 1

---

## Dependency graph

```
Slice 1 → Slice 2 → Slice 3 → Slice 4
              ↓           ↓
          Slice 6     Slice 5
```

## Summary

| Slice | What | Depends |
|-------|------|---------|
| 1 | Pub-key spend + payTo + draft | — |
| 2 | Script spend + mint + redeemer indices | 1 |
| 3 | Peek convergence + build loop | 2 |
| 4 | Ctx + pluggable queries | 3 |
| 5 | Valid + library checkers | 3 |
| 6 | Reference inputs + validity intervals | 1 |
