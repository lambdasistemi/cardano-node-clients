# Research: TxBuild Conway collateral fields

**Feature**: [spec.md](./spec.md) — Issue [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124).

## Decisions

### Decision 1 — Resolution map for collateral input lovelace sum

**Decision**: Reuse the existing `inputUtxos :: [(TxIn, TxOut ConwayEra)]` argument that `buildWith`/`balanceTx` already accept. At balancing time, compute `sum(collateral lovelace)` by intersecting `body ^. bodyTxL . collateralInputsTxBodyL` with `inputUtxos`.

**Rationale**: The convention that exists today (verified in `test/Cardano/Node/Client/E2E/MultiAssetChangeSpec.hs`, line 167–177) is that callers pass every UTxO that any instruction in the program references — the same `seedIn` is both `spend`'d and used as `collateral`, and `inputUtxos = [seed]` covers both. Adding a new `collateralUtxos` parameter would break that convention and force every caller to thread the same UTxO through twice.

**Alternatives considered**:
- New `collateralUtxos :: [(TxIn, TxOut)]` parameter on `buildWith`/`balanceTx`. Rejected: breaking change for every existing caller, no semantic benefit. The body already carries the `Set TxIn` of collateral inputs, and the resolution map already exists.
- Have `TxBuild` instructions carry the resolved `TxOut` inline (`Collateral :: TxIn -> TxOut -> TxInstr ...`). Rejected: forces callers to pre-resolve at program-construction time, which is awkward for callers that read UTxO state after the program is written.

### Decision 2 — Where collateral arithmetic lives in the build pipeline

**Decision**: Inside `Cardano.Node.Client.Balance.balanceTx`'s fee fixpoint loop.

**Rationale**: The two new fields' CBOR bytes are part of the body's signed size; the fee depends on them; their values depend on the fee. Putting the derivation inside the loop turns this circular dependency into a single converging fixpoint, identical in shape to the existing fee/output fixpoint. Putting it outside (e.g. as a post-balance pass in `buildWith`) would require an additional iteration over `balanceTx` to absorb the size delta.

**Alternatives considered**:
- Pre-set worst-case placeholder values before `balanceTx`, run the existing loop, then fix up. Rejected: the worst-case placeholder must over-estimate the size (otherwise `estimateMinFeeTx` under-shoots). Over-estimating wastes a few lovelace per tx and adds a special-case post-pass — same convergence cost as just doing it inside the loop, but messier.
- Put the derivation inside `buildWith` and pass through `balanceTx` unchanged. Rejected: the existing `BalanceResult { changeIndex }` and the `bumpFee` retry path already entangle balance state with fee state; the derivation needs to live next to the fee loop to remain coherent.

### Decision 3 — Caller signal for the override return address

**Decision**: Add a `Maybe Addr` parameter to `balanceTx` (`mCollReturnOverride`). `buildWith` reads `tsCollReturnAddr` from the interpreter state and passes it through.

**Rationale**: `balanceTx` already takes `changeAddr :: Addr` for the change output. Adding a sibling optional parameter is symmetric and self-documenting. Threading the address via a new field on `BalanceResult` would be backwards (the address is an input, not an output).

**Alternatives considered**:
- Encode the override into the body before calling `balanceTx` (e.g. set `collateral_return.address` to the override and leave `value = 0`, then have `balanceTx` only update the value). Rejected: requires `balanceTx` to recognise a magic "value=0 means update me" sentinel, which is fragile and obscures the contract.
- A dedicated configuration record threaded into both `buildWith` and `balanceTx`. Rejected: premature — current callers do not need a knob bag.

### Decision 4 — Public-API surface for the override

**Decision**: One new combinator `setCollateralReturn :: Addr -> TxBuild q e ()`. No combinator for `total_collateral` coin or `collateral_return` value.

**Rationale**: Both derived values are mandated by ledger arithmetic. A caller-supplied override would only produce an invalid tx that the chain rejects. `cardano-cli transaction build` exposes `--tx-out-return-collateral <addr>` (address only) and never an absolute coin override; matching that behaviour is the principle of least surprise.

**Alternatives considered**:
- Expose `setTotalCollateral :: Coin -> TxBuild q e ()` "for power users". Rejected: the user explicitly chose option 1 (no setter) when the API was reviewed mid-issue. `total_collateral` is a protocol-driven field; an override is footgun-only.
- Expose a single `setCollateral :: CollateralConfig -> TxBuild q e ()` knob bag. Rejected: only one knob exists today; a record-shaped API is over-engineering for a single field.

### Decision 5 — Convergence safety of the extended fee loop

**Decision**: Existing 10-iteration cap stays. No change to convergence logic.

**Rationale**: The CBOR sizes of `total_collateral` (a varint `Coin`) and `collateral_return` (a `TxOut` with a fixed-shape lovelace-only value) are both bounded by ~10 bytes each across the realistic fee range. A fee delta `Δf` produces at most a few bytes of size delta, which in turn changes the next-iteration fee by `~txFeePerByte × Δsize ≈ 44 × few = O(100 lovelace)` — well under any plausible `Δf` (typically thousands of lovelace). The loop converges in 2–3 rounds, same as today. The 10-iteration cap is a defensive ceiling, not a tight bound.

**Alternatives considered**:
- Bump the iteration cap to 20 "to be safe". Rejected: no evidence of need; would mask real divergence bugs if introduced later.

### Decision 6 — What to do when the body has scripts but no collateral inputs (or vice versa)

**Decision**:
- Body has redeemers but **no** collateral inputs: out of scope for this feature. Pass through to `balanceTx` unchanged (do not emit `total_collateral`/`collateral_return`). The chain will reject the resulting tx; that error path is unchanged from today.
- Body has collateral inputs but **no** redeemers: do not emit either field (FR-008). Matches `cardano-cli`'s behaviour for non-script txs.
- Body has redeemers AND collateral inputs but `sum(collateral input lovelace) < total_collateral_required`: surface a new `BalanceError` (`CollateralShortfall`). FR-009.

**Rationale**: Each of these edge cases is already part of the spec. The library should fail fast and visibly when the program is internally inconsistent; it should not paper over caller mistakes by synthesising inputs or emitting mathematically nonsensical fields.

## Open issues / not resolved here

None blocking implementation. Two follow-ups deferred:

- **Reference-script-only collateral**: a tx may reference a script via `referenceInputsTxBodyL` rather than `attachScript`. The "has redeemers" predicate (`null . unRedeemers . view rdmrsTxWitsL`) covers both cases (every Plutus invocation needs a redeemer regardless of how the script bytes are sourced), so no special handling is needed. Re-confirm during implementation.
- **Future eras after Conway**: this feature targets Conway-only because that is all `build` produces. If a successor era arrives with a different collateral model, this code will need a per-era branch — but until that era is real, there is nothing to plan.
