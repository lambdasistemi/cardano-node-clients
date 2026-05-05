# Implementation Plan: TxBuild Conway collateral fields

**Branch**: `040-txbuild-conway-collateral` | **Date**: 2026-05-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [spec.md](./spec.md). Source issue: [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124).

## Summary

Wire `total_collateral` and `collateral_return` into the body produced by `Cardano.Node.Client.TxBuild.build`. The values are mandatory for any Conway tx that has script witnesses + collateral inputs and the chain rejects bodies that omit them. `total_collateral = ceil(fee × collateralPercent / 100)` and `collateral_return.value.coin = sum(collateral_input.lovelace) − total_collateral` are fully derived during balancing; only the return *address* is caller-overridable through a new `setCollateralReturn :: Addr -> TxBuild q e ()` combinator (default: the existing change address).

The work touches three layers:
1. `TxBuild` DSL: one new `TxInstr`, one new smart constructor, one new `TxState` field.
2. `Balance.balanceTx`: extend the fee fixpoint to re-derive both fields per iteration so `estimateMinFeeTx` accounts for their CBOR bytes (currently 76 missing bytes ≈ 3344 lovelace shortfall).
3. Tests: extend the existing `TxBuildSpec` (unit) and `E2E/TxBuildSpec` / `MultiAssetChangeSpec` (e2e) coverage to assert the body shape and chain acceptance.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.2 (matches existing flake-pinned toolchain).
**Primary Dependencies**: `cardano-ledger-conway` (1.21), `cardano-ledger-babbage` (1.13, supplies `totalCollateralTxBodyL` / `collateralReturnTxBodyL`), `cardano-ledger-alonzo` (supplies `ppCollateralPercentageL`), `cardano-ledger-api` (`estimateMinFeeTx`). All are already in the closure.
**Storage**: N/A — pure tx assembly; no persistence change.
**Testing**: HSpec (unit + e2e). E2E tests run against a local Conway devnet (`Cardano.Node.Client.Devnet.withCardanoNode`).
**Target Platform**: Linux dev/CI (NixOS / `nix develop`). No platform-specific code.
**Project Type**: Library (`cardano-node-clients`) — single project layout under `lib/` + `test/`.
**Performance Goals**: The fee fixpoint already converges in 2–3 rounds and caps at 10. Adding two fields whose sizes are bounded by ~10 bytes each must not change this convergence.
**Constraints**: No new caller-facing breaking changes beyond the additive `setCollateralReturn`. Existing non-script flows (golden vectors, `TxBuildGoldenSpec`) must produce byte-identical output (covered by SC-005).
**Scale/Scope**: Library-internal change. Affects every downstream consumer that builds script-bearing Conway txs (currently: `amaru-treasury-tx`, internal Plutus flows).

## Constitution Check

Constitution principles ([memory/constitution.md](../../.specify/memory/constitution.md)):

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Channel-Driven N2C Clients | ✅ N/A | This feature touches the pure tx-assembly layer, not the channel layer. |
| II. Devnet E2E Testing | ✅ | New e2e coverage runs against `withCardanoNode` like every other E2E test. No mocking. |
| III. Minimal Dependencies | ✅ | Only adds one extra import (`ppCollateralPercentageL` from `cardano-ledger-alonzo`, already in the closure). No new packages. |
| IV. Test Utilities Are First-Class | ✅ | Any test helper introduced (e.g. a shared "build a script-bearing tx" fixture) lives under the test library so other consumers can reuse it. |

Quality gates (`just ci` passes, e2e runs against real devnet, no mocks): all enforceable, no exceptions requested.

**Result**: PASS. No constitutional violations. Complexity Tracking section omitted.

## Project Structure

### Documentation (this feature)

```text
specs/040-txbuild-conway-collateral/
├── plan.md                # This file
├── spec.md                # Feature spec
├── research.md            # Phase 0 output
├── data-model.md          # Phase 1 output
├── quickstart.md          # Phase 1 output
├── contracts/
│   └── txbuild-api.md     # The single new caller-facing contract: setCollateralReturn
├── checklists/
│   └── requirements.md    # Spec-quality validation
└── tasks.md               # Created later by /speckit.tasks
```

### Source Code (repository root)

```text
lib/
└── Cardano/
    └── Node/
        └── Client/
            ├── TxBuild.hs       # ← modify: TxInstr, smart constructor, TxState, buildWith wiring
            └── Balance.hs       # ← modify: extend balanceTx fee fixpoint with collateral derivation

test/
└── Cardano/
    └── Node/
        └── Client/
            ├── TxBuildSpec.hs              # ← extend: assert body shape for new code paths
            ├── TxBuildGoldenSpec.hs        # ← may need new vectors for script-bearing txs
            └── E2E/
                ├── TxBuildSpec.hs          # ← extend: end-to-end script tx that previously failed
                └── MultiAssetChangeSpec.hs # ← already exercises collateral; assert new fields appear
```

**Structure Decision**: Single-project library layout (the existing one). All changes confined to `lib/Cardano/Node/Client/{TxBuild,Balance}.hs` and the corresponding test modules. No new modules.

## Phase 0: Outline & Research

See [research.md](./research.md) for the full record. Open questions resolved:

1. **Where does the lovelace sum of collateral inputs come from?** — Resolved. The `inputUtxos` argument already passed into `buildWith` and `balanceTx` is the resolved `[(TxIn, TxOut)]` map for *all* inputs the tx may reference (regular spends + collateral). Existing tests (`MultiAssetChangeSpec`) confirm the convention: `collateral seedIn` and `spend seedIn` reference the same UTxO, and the caller passes that single resolved UTxO once via `inputUtxos`. Lookup at balancing time: filter `inputUtxos` by `body ^. collateralInputsTxBodyL`, sum `coinTxOutL`.

2. **Should collateral arithmetic live inside `balanceTx` or in `buildWith`?** — Resolved. Inside `balanceTx`. The fields' sizes interact with the fee fixpoint, and putting them outside the loop would require a redundant second pass. `balanceTx` already takes `pp` (for `collateralPercent`) and `inputUtxos` (for the lovelace sum); it just needs a way to know the desired return address.

3. **How does `balanceTx` learn the collateral-return address?** — Resolved. Add a single new `Maybe Addr` parameter (`mCollReturnOverride`) to `balanceTx`. When `Nothing`, fall back to the `changeAddr` already passed in. `buildWith` derives this from `tsCollReturnAddr`.

4. **Convergence safety**: extending the fixpoint to also re-derive `total_collateral` and `collateral_return.value` per iteration. — Resolved. The CBOR sizes of both fields are bounded (≤ 10 bytes each across the entire range of fees and collateral sums on mainnet). Each fee delta `Δf` propagates a bounded `Δsize`, which in turn changes the next-iteration fee by `≪ Δf`. Existing 10-iteration cap stays sufficient.

5. **What if the body has scripts but collateral inputs are missing?** — Resolved. The existing chain rejection path is preserved; this feature does not synthesise inputs (FR scope already excludes this).

## Phase 1: Design & Contracts

### Data model changes ([data-model.md](./data-model.md))

- `TxInstr q e a` — add a constructor `SetCollReturn :: Addr -> TxInstr q e ()`.
- `TxState e` — add field `tsCollReturnAddr :: StrictMaybe Addr` (last-write-wins, like `tsValidFrom`/`tsValidTo`). Default: `SNothing`.
- `BalanceError` — add `CollateralShortfall !Coin !Coin` (required total-collateral, available collateral-input sum) for the FR-009 case.
- No changes to `BalanceResult`, `BuildError`, `BuildOptions`.

### Caller-facing contract ([contracts/txbuild-api.md](./contracts/txbuild-api.md))

The single new public symbol:

```haskell
-- | Set the address that receives the collateral-return output.
--   If never called, defaults to the change address passed to 'build'.
--   Last-write-wins: calling this multiple times keeps only the final address.
setCollateralReturn :: Addr -> TxBuild q e ()
```

No other public-API change. `build` and `buildWith` keep their existing signatures.

### Algorithm sketch (no code, semantics only)

Inside the existing `balanceTx` fee fixpoint loop, after each `buildTx fee`:

```text
if body has at least one redeemer AND at least one collateral input:
  totalCollateralCoin = ceil(fee * collateralPercent / 100)
  collIns       = body.collateralInputs        -- Set TxIn
  collInLovelace = sum [coinTxOutL of inputUtxos[i] for i in collIns]
  if collInLovelace < totalCollateralCoin:
    abort with CollateralShortfall(required = totalCollateralCoin,
                                   available = collInLovelace)
  returnAddr = mCollReturnOverride `orElse` changeAddr
  returnVal  = MaryValue (collInLovelace - totalCollateralCoin) mempty
  body.totalCollateral  = SJust totalCollateralCoin
  body.collateralReturn = SJust (mkBasicTxOut returnAddr returnVal)
else:
  -- preserve existing behaviour; do not emit either field
  body.totalCollateral  = SNothing
  body.collateralReturn = SNothing
```

The existing `estimateMinFeeTx` then sees the populated body and returns a fee that already covers the new bytes. Convergence check (`newFee <= currentFee`) is unchanged.

### Quickstart ([quickstart.md](./quickstart.md))

A 30-line script using the public DSL that produces a script-bearing tx with the new fields populated. Useful as a smoke test and as documentation for downstream callers. Will be runnable from `cabal repl test:cardano-node-clients-test` against the existing Plutus fixtures.

### Agent context update

`CLAUDE.md` already lists the relevant tech (`cardano-ledger-conway`, GHC 9.6+). No new technologies introduced — the agent context update is a no-op for this feature; running `update-agent-context.sh` will record the spec ID under "Recent Changes".

## Re-evaluated Constitution Check (post-Phase-1)

No new violations surfaced during design. The `Maybe Addr` addition to `balanceTx` is internal (the function is exported but the change is a single optional argument; rather than break callers, we can keep the existing 5-arg `balanceTx` as a wrapper around a new 6-arg primitive — to be confirmed in Phase 2 tasks). Constitution check: PASS.

## Complexity Tracking

No violations to track.
