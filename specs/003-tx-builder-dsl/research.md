# Research: Transaction Builder DSL

## Decision: Builder pattern

**Chosen**: Immutable record with step list, combinators return new record via `&` pipeline.
**Rationale**: Mirrors Scalus TxBuilder (proven API), fits Haskell idioms (no OOP chaining, use `&` instead).
**Alternatives**: Monadic builder (State monad) — rejected because `&` is simpler and doesn't require do-notation for pure construction.

## Decision: Redeemer/datum typing

**Chosen**: Existential `ToData` constraint captured in `SpendWitness` / `MintWitness` constructors.
**Rationale**: Type-safe at call sites (callers pass typed values), erased at assembly time. No raw `PLC.Data` in public API.
**Alternatives**: Store `PLC.Data` directly (simpler but loses type safety at construction).

## Decision: Index computation

**Chosen**: Compute `spendingIndex` and minting index inside `build` from the sorted input/policy sets.
**Rationale**: This is the primary boilerplate. Every MPFS builder computes these manually.
**Source**: `spendingIndex` in `Cardano.MPFS.TxBuilder.Real.Internal` (lines 508-517).

## Decision: Integrity hash

**Chosen**: Compute inside `build` from `PParams` + assembled `Redeemers`.
**Rationale**: Currently computed manually in every builder. Uses `hashScriptIntegrity` from cardano-ledger-alonzo.
**Source**: `computeScriptIntegrity` in Internal.hs (lines 521-533).

## Decision: Evaluation + balancing

**Chosen**: `build` calls evaluateTx (via Provider), patches ExUnits, recomputes integrity hash, then calls existing `balanceTx`.
**Rationale**: This is the `evaluateAndBalance` function from Internal.hs — moved into the builder as the final step.
**Source**: `evaluateAndBalance` in Internal.hs (lines 188-267).

## Decision: No separate burn combinator

**Chosen**: `mint` handles both minting (positive) and burning (negative), following Scalus.
**Rationale**: Simpler API, no semantic distinction needed — the sign of the quantity determines the operation.

## Decision: PlutusV3 only (for now)

**Chosen**: Hardcode PlutusV3 in integrity hash computation (language views).
**Rationale**: All MPFS transactions are PlutusV3. Can be parameterized later if needed.
