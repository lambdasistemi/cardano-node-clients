# Contract: TxBuild caller-facing API

**Feature**: [spec.md](../spec.md). Issue: [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124).

## New public symbols

```haskell
module Cardano.Node.Client.TxBuild where

-- | Set the address that receives the collateral-return output.
--
--   Only meaningful for Conway txs that have script witnesses
--   and at least one collateral input. Ignored otherwise (a
--   non-script tx never emits @collateral_return@ regardless).
--
--   If never called, defaults to the @changeAddr@ argument of
--   'build' / 'buildWith'.
--
--   Last-write-wins: calling this multiple times keeps only the
--   final address, matching 'setValidFrom' / 'setValidTo'.
setCollateralReturn :: Addr -> TxBuild q e ()
```

## New error case

```haskell
module Cardano.Node.Client.Balance where

data BalanceError
  = ...
  | -- | The collateral inputs supply less lovelace than the
    --   protocol-required @ceil(fee × collateralPercent / 100)@.
    --   Carries (required, available).
    CollateralShortfall !Coin !Coin
  ...
```

This propagates through `BuildError` via the existing `BalanceFailed` constructor; no new `BuildError` constructor is needed.

## Unchanged signatures

`build` and `buildWith` keep their existing signatures verbatim:

```haskell
build ::
    PParams ConwayEra ->
    InterpretIO q ->
    (ConwayTx -> IO (Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))) ->
    [(TxIn, TxOut ConwayEra)] ->
    [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    TxBuild q e a ->
    IO (Either (BuildError e) ConwayTx)

buildWith ::
    BuildOptions ->
    PParams ConwayEra ->
    InterpretIO q ->
    (ConwayTx -> IO (Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))) ->
    [(TxIn, TxOut ConwayEra)] ->
    [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    TxBuild q e a ->
    IO (Either (BuildError e) ConwayTx)
```

The semantic change is post-balancing the body now contains `total_collateral` / `collateral_return` whenever the program has redeemers + at least one `collateral txIn`.

## Internal-only signature change (acceptable)

`Cardano.Node.Client.Balance.balanceTx` gains one parameter:

```haskell
balanceTx ::
    PParams ConwayEra ->
    [(TxIn, TxOut ConwayEra)] ->
    [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    Maybe Addr ->                  -- NEW: optional collateral-return address override
    ConwayTx ->
    Either BalanceError BalanceResult
```

`balanceTx` is exported (`Cardano.Node.Client.Balance` re-exports it), but no external caller currently invokes it directly — `buildWith` is the only consumer. To avoid an unnecessary breaking change for any out-of-tree consumer, we will:

1. Rename the new function to `balanceTxWithCollateral` (or add the override parameter as a record-shaped `BalanceCollateral` config).
2. Keep `balanceTx :: ... -> Either BalanceError BalanceResult` (5-arg) as a thin wrapper that passes `Nothing`.

Final shape will be confirmed in `tasks.md` (Phase 2) once the implementation order is fixed.

## Backwards compatibility

| Surface | Change | Compatibility |
|---------|--------|---------------|
| `setCollateralReturn` | Added | New — no compat impact |
| `BalanceError` | New constructor | Source-compatible; non-exhaustive pattern matches will warn |
| `build`/`buildWith` | Same signatures | Wire-compatible; behaviour now produces different body bytes for **script-bearing txs only** |
| `balanceTx` | Optional new param via wrapper | Source-compatible (5-arg form preserved) |
| Non-script tx output | Unchanged | Byte-identical (SC-005) |
