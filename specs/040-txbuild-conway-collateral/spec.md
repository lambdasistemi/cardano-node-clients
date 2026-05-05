# Feature Specification: TxBuild Conway collateral fields

**Feature Branch**: `040-txbuild-conway-collateral`
**Created**: 2026-05-05
**Status**: Draft
**Input**: Issue [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124) — TxBuild does not populate the Conway body fields `total_collateral` (CBOR key 17) and `collateral_return` (CBOR key 16). Discovered while reproducing a real treasury swap tx in [amaru-treasury-tx#18](https://github.com/lambdasistemi/amaru-treasury-tx/pull/18).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Script-bearing tx is mempool-acceptable out of the box (Priority: P1)

A caller writes a `TxBuild` program that spends a Plutus-locked UTxO and adds at least one collateral input. They call `build` and submit the resulting tx. The chain accepts it.

**Why this priority**: Without this story the library cannot produce any submittable script-bearing tx. The chain rejects script-bearing Conway txs that omit `total_collateral` or `collateral_return`. Every Plutus-driven flow built on `TxBuild` is currently broken at the mempool.

**Independent Test**: Build a minimal tx that spends a Plutus-locked UTxO, attaches a single collateral input, and lands change at the caller's address. Submit to a Conway-era node. The body must contain both fields, `total_collateral` must equal `ceil(fee × collateralPercent / 100)`, and the lovelace balance `sum(collateral_inputs) = total_collateral + collateral_return.value` must hold exactly.

**Acceptance Scenarios**:

1. **Given** a `TxBuild` program with one Plutus spend and one collateral input, **When** the caller runs `build` and inspects the result, **Then** the body has 12 map entries (not 10), with `total_collateral` and `collateral_return` populated and the collateral arithmetic balanced to the lovelace.
2. **Given** the same program submitted to a real Conway node, **When** the node validates it, **Then** the tx clears the `BabbageEraTxOut` collateral arithmetic predicate without "missing total_collateral" rejections.
3. **Given** a `TxBuild` program with neither scripts nor collateral inputs, **When** the caller runs `build`, **Then** the body contains neither `total_collateral` nor `collateral_return` (these fields stay absent for non-script txs, matching pre-feature behaviour).

---

### User Story 2 - Fee converges with collateral fields counted (Priority: P1)

A caller runs `build` on a script-bearing tx with collateral inputs. The reported fee already accounts for the bytes that `total_collateral` and `collateral_return` will occupy in the final body — the tx is not rejected at submission for `FeeTooSmallUTxO`, and the fee does not need a manual top-up.

**Why this priority**: Without this story, the fee estimator under-counts by ~76 bytes (~3344 lovelace at base `txFeePerByte = 44`), producing txs that look correct but are immediately rejected by the mempool. This is the second half of making `build` actually usable for script-bearing flows.

**Independent Test**: Run `build` on the swap-probe shape from [amaru-treasury-tx#18](https://github.com/lambdasistemi/amaru-treasury-tx/pull/18) and compare its body byte length to `cardano-cli transaction build`'s output for the same inputs. The two byte counts must match.

**Acceptance Scenarios**:

1. **Given** a script-bearing tx with collateral inputs, **When** `build` returns, **Then** the fee field already reflects the bytes consumed by `total_collateral` and `collateral_return` (no shortfall vs. `cardano-cli`).
2. **Given** the same inputs, **When** the resulting CBOR body is submitted, **Then** the node does not reject with `FeeTooSmallUTxO`.

---

### User Story 3 - Caller redirects collateral return to a chosen address (Priority: P2)

A caller has separate "operational" and "collateral" wallets. They call `setCollateralReturn collateralRefundAddr` so the leftover from collateral inputs lands in the collateral wallet, not in the change wallet that receives the tx outputs' change.

**Why this priority**: This is the only legitimate caller-facing override exposed by this feature. P2 (not P1) because the default — return to change address — already produces a valid, submittable tx; this story is only needed for callers who actively want a different return target.

**Independent Test**: Build a script-bearing tx with `setCollateralReturn customAddr`, then verify the tx body's `collateral_return` output's address equals `customAddr` (not the change address) and the lovelace amount equals `sum(collateral_inputs) − total_collateral`.

**Acceptance Scenarios**:

1. **Given** a `TxBuild` program that calls `setCollateralReturn collateralAddr`, **When** `build` runs, **Then** `collateral_return.address = collateralAddr` and the collateral arithmetic still balances exactly.
2. **Given** a program that does not call `setCollateralReturn`, **When** `build` runs, **Then** `collateral_return.address` equals the change address passed to `build`.

---

### Edge Cases

- A program declares collateral inputs but no scripts (no redeemers): the chain does not require `total_collateral`/`collateral_return` for non-script txs. The library MUST NOT add the fields in this case (adding them on a no-script tx is a spec violation).
- A program declares scripts but no collateral inputs: this is an invalid program for any era that requires collateral on script-bearing txs. Behaviour stays as today — the chain rejects the tx for the missing collateral input set; this feature does not synthesise collateral inputs.
- The sum of collateral inputs is less than `ceil(fee × collateralPercent / 100)`: the resulting `collateral_return` value would be negative. `build` MUST surface this as a `BuildError` (existing balance/insufficient-funds error category) rather than producing a malformed body.
- The sum of collateral inputs equals `total_collateral` exactly: `collateral_return.value` is zero. The library MUST still emit a `collateral_return` output (with zero lovelace) so the body byte count remains stable across iterations of the fee fixpoint and the mempool predicate's arithmetic check has both endpoints to compare.
- The protocol parameter `collateralPercent` is zero (theoretical): `total_collateral = 0`. The fields are still emitted; the collateral inputs are returned in full.
- The chosen collateral-return address has a value below the protocol-parameter `minUTxOValue`: the resulting output would be ledger-rejected. This is a caller mistake (they picked a return address with insufficient leftover) and surfaces as a normal balance failure during the fee/balance fixpoint.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `build` MUST populate `total_collateral` on the resulting tx body whenever the body has at least one redeemer (i.e. a script witness) AND at least one collateral input.
- **FR-002**: `build` MUST set `total_collateral = ceil(fee × collateralPercent / 100)`, where `fee` is the converged fee from balancing and `collateralPercent` is read from the protocol parameters supplied to `build`.
- **FR-003**: `build` MUST populate `collateral_return` on the resulting tx body under the same condition as FR-001.
- **FR-004**: `build` MUST set `collateral_return.value.coin = sum(collateral_inputs.value.coin) − total_collateral` and `collateral_return.value.assets = ∅` (lovelace-only return).
- **FR-005**: `build` MUST set `collateral_return.address` to the value passed to `setCollateralReturn` if the program called it; otherwise to the `changeAddr` argument of `build`/`buildWith`.
- **FR-006**: The fee estimator inside `buildWith` MUST account for the CBOR bytes of `total_collateral` and `collateral_return` before the fee converges, so the returned fee covers the final body without a post-balance shortfall.
- **FR-007**: `TxBuild` MUST expose a smart constructor `setCollateralReturn :: Addr -> TxBuild q e ()` that records the override address. The library MUST NOT expose any setter for the `total_collateral` lovelace amount or for the `collateral_return` lovelace amount — these are fully derived.
- **FR-008**: When the body has no redeemers, `build` MUST NOT add `total_collateral` or `collateral_return`, regardless of whether collateral inputs are present (preserves pre-feature behaviour for non-script flows).
- **FR-009**: When `sum(collateral_inputs.value.coin) < ceil(fee × collateralPercent / 100)`, `build` MUST surface a `BuildError` rather than emit a body with a negative-valued `collateral_return`.
- **FR-010**: A program that calls `setCollateralReturn` more than once MUST behave as if only the last call happened (last-write-wins, matching the existing semantics of `SetValidFrom` / `SetValidTo`).

### Key Entities

- **TxBuild program**: a sequence of instructions describing intent (spends, mints, withdrawals, …). Augmented in this feature with one new instruction (`SetCollReturn`) and one new optional state field (collateral-return address).
- **TxState**: the interpreter's accumulated state. Gains a single optional field for the explicit collateral-return address override.
- **Conway tx body**: the output artifact. Gains two CBOR fields when the body has scripts + collateral inputs: `total_collateral` (key 17, `Coin`) and `collateral_return` (key 16, `TxOut`).
- **Protocol parameters**: read-only input to `build`. The `collateralPercent` field drives `total_collateral`'s value.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A script-bearing tx built with `build` and submitted to a Conway node receives no "missing `total_collateral`" or "missing `collateral_return`" rejection (failure rate goes from 100% to 0% for the swap-probe shape).
- **SC-002**: For the swap-probe inputs from [amaru-treasury-tx#18](https://github.com/lambdasistemi/amaru-treasury-tx/pull/18), the body byte length produced by `build` matches `cardano-cli transaction build`'s output exactly (delta ≤ 0 bytes; today the gap is 76 bytes).
- **SC-003**: The fee returned by `build` is within the slack accepted by the chain — i.e. the body never fails submission with `FeeTooSmallUTxO` due to under-counted collateral-field bytes (today's residual ~3344 lovelace shortfall is eliminated).
- **SC-004**: The lovelace-balance invariant `sum(collateral_inputs.value.coin) = total_collateral + collateral_return.value.coin` holds exactly in every output of `build` (verifiable by reading the body).
- **SC-005**: For non-script txs (no redeemers), the body emitted by `build` is byte-identical to the pre-feature output (no regression on the `TxBuildGoldenSpec` golden vectors that exercise non-script flows).

## Assumptions

- Callers supply a `PParams ConwayEra` to `build`; `collateralPercent` is read from this value (not from a separately-passed argument). This matches the existing API shape.
- The collateral-return output is always lovelace-only. Returning multi-assets in `collateral_return` is not in scope — `cardano-cli` does not do it either, and no current caller has asked for it.
- The library does not synthesise collateral inputs. If a script-bearing program forgets to call `collateral`, the existing failure path (chain rejection at submission) is unchanged.
- The fee fixpoint already implemented in `Cardano.Node.Client.Balance.balanceTx` can be extended to also re-derive `total_collateral` / `collateral_return` per iteration without changing its convergence guarantees (both fields' CBOR sizes are bounded by a few bytes).
- No on-disk format or wire format outside the tx body changes. This is purely a body-construction fix; downstream consumers (submit clients, golden vectors for script-bearing txs) get a richer body and the chain accepts it.

## Out of Scope

- Caller-supplied absolute `total_collateral` value: `collateralPercent` is a protocol parameter and the formula is mandatory; an override would only produce invalid txs.
- Caller-supplied `collateral_return` lovelace amount: derived from inputs and `total_collateral`; an override breaks the lovelace-conservation invariant.
- Multi-asset collateral returns.
- Synthesising collateral inputs when the program omits them.
- Pre-Babbage eras (Conway only — that's all `build` produces today).
