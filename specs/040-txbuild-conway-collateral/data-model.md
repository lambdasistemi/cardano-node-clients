# Data Model: TxBuild Conway collateral fields

**Feature**: [spec.md](./spec.md). Implementation plan: [plan.md](./plan.md).

## Changed types

### `TxInstr q e a` (in `lib/Cardano/Node/Client/TxBuild.hs`)

Add one constructor:

```haskell
-- | Override the address for the collateral-return output.
SetCollReturn :: Addr -> TxInstr q e ()
```

Existing constructors are unchanged.

### `TxState e` (in `lib/Cardano/Node/Client/TxBuild.hs`)

Add one field:

```haskell
data TxState e = TxState
  { ...
  , tsCollReturnAddr :: StrictMaybe Addr   -- NEW; default: SNothing
  , ...
  }
```

`emptyState` initialises it to `SNothing`. `interpretWithM`'s `SetCollReturn addr :>>= k` branch sets it to `SJust addr` (last-write-wins, matching the existing `SetValidFrom` / `SetValidTo` pattern).

### `BalanceError` (in `lib/Cardano/Node/Client/Balance.hs`)

Add one constructor:

```haskell
data BalanceError
  = ...
  | CollateralShortfall !Coin !Coin
  --   ^ required total_collateral ^ available sum(collateral_input.lovelace)
  ...
```

Existing constructors and the `Eq`/`Show` derivations are unchanged.

## Unchanged but referenced

These types are part of the contract but receive no field-level changes:

- `BalanceResult { balancedTx, changeIndex }` — same shape; the balanced tx now carries the new body fields when applicable.
- `BuildError e` — `BalanceFailed BalanceError` automatically covers the new `CollateralShortfall` case.
- `BuildOptions` — no new knobs.
- `Cardano.Node.Client.Ledger.ConwayTx` — same era; the new fields live on the body via the existing ledger lenses (`totalCollateralTxBodyL`, `collateralReturnTxBodyL`).

## Validation rules

| Rule | Source | Enforcement point |
|------|--------|-------------------|
| If body has no redeemers → both new fields absent | FR-008 | `balanceTx` post-`buildTx` step |
| If body has redeemers AND collateral inputs → both new fields present | FR-001, FR-003 | `balanceTx` post-`buildTx` step |
| `total_collateral = ceil(fee × collateralPercent / 100)` | FR-002 | `balanceTx` per-iteration recompute |
| `collateral_return.value = sum(collateral_input.lovelace) − total_collateral` (lovelace only) | FR-004 | `balanceTx` per-iteration recompute |
| Address = `tsCollReturnAddr` if set, else `changeAddr` | FR-005 | `buildWith` resolves and passes to `balanceTx` |
| `sum(coll input lovelace) ≥ total_collateral` | FR-009 | `balanceTx` aborts with `CollateralShortfall` otherwise |
| Last `setCollateralReturn` wins | FR-010 | Interpreter assigns `SJust addr` unconditionally |

## Helpers (private)

Two small private helpers in `Balance.hs`:

```haskell
-- | Compute total_collateral and the lovelace-balanced collateral_return.
--   Returns Nothing when the body has no redeemers (no fields to emit).
deriveCollateralFields ::
  PParams ConwayEra ->
  [(TxIn, TxOut ConwayEra)] ->   -- inputUtxos
  Addr ->                         -- effective return addr
  Coin ->                         -- balanced fee
  ConwayTx ->
  Either BalanceError (Maybe (Coin, TxOut ConwayEra))
```

```haskell
-- | Sum the lovelace coins of UTxOs whose TxIn is in the given set.
lookupCollateralLovelace ::
  Set TxIn ->
  [(TxIn, TxOut ConwayEra)] ->
  Coin
```

These are private to `Balance.hs` (not exported) — they exist only to keep the per-iteration loop body legible.

## Migration / compatibility

- **Wire format**: Conway tx body grows two optional fields when applicable. Bodies for non-script txs are byte-identical to today's output.
- **API**: One additive function (`setCollateralReturn`). One additive constructor on `BalanceError`. No removed or renamed symbols.
- **Persistence**: None — the library does not persist tx state.
- **Downstream consumers**: A consumer that pattern-matches on `BalanceError` exhaustively will get a non-exhaustive-pattern warning until they handle `CollateralShortfall`. This is desired (consumers currently treat the absence of this error as silent success).
