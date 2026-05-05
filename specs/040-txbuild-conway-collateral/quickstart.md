# Quickstart: Building a script-bearing Conway tx

**Feature**: [spec.md](./spec.md). Issue: [#124](https://github.com/lambdasistemi/cardano-node-clients/issues/124).

## What changes for callers

Before this feature, `build` produced a body that the chain rejected for any Plutus-driven tx (missing `total_collateral` / `collateral_return`). After this feature, the same program produces a submittable body.

## Default usage (no API change)

```haskell
import Cardano.Node.Client.TxBuild
import Cardano.Node.Client.Balance ()

let prog :: TxBuild NoQ Void ()
    prog = do
      _ <- spend scriptIn               -- Plutus-locked UTxO
      collateral feeIn                  -- Collateral input
      attachScript myValidator
      _ <- payTo recipientAddr (inject (Coin 3_000_000))
      pure ()

result <- build pp interpret evaluator
                [feeUtxo, scriptUtxo]   -- inputUtxos: covers BOTH spend + collateral
                []                       -- refUtxos
                changeAddr
                prog
```

That's it. The resulting `ConwayTx` now carries `total_collateral` and `collateral_return` (return target = `changeAddr`).

## Override the collateral-return address

```haskell
let prog = do
      _ <- spend scriptIn
      collateral feeIn
      attachScript myValidator
      setCollateralReturn collateralWalletAddr   -- ← new
      _ <- payTo recipientAddr (inject (Coin 3_000_000))
      pure ()
```

Now the leftover from the collateral input lands at `collateralWalletAddr`, while the change from the regular spend stays at `changeAddr`.

## What you get back

For a script-bearing tx (at least one redeemer + at least one collateral input):

| Body field | Value |
|------------|-------|
| `inputs` | as before |
| `outputs` | as before + change output appended |
| `collateral_inputs` | as before |
| `collateral_return` | NEW: `(returnAddr, sum(collateral_input.lovelace) − total_collateral)` |
| `total_collateral` | NEW: `ceil(fee × collateralPercent / 100)` |
| `fee` | now correctly accounts for the bytes of the two new fields |

For a non-script tx (no redeemers): output is byte-identical to today.

## What can go wrong

```haskell
case result of
  Right tx -> submit tx
  Left (BalanceFailed (CollateralShortfall required available)) ->
    -- caller's collateral inputs cover only `available`,
    -- but the protocol needs at least `required`.
    -- Fix: provide a larger collateral input.
    ...
  Left otherErr -> ...
```

This error is new in this feature. All other `BuildError` cases are unchanged.

## Verification (smoke test)

```haskell
case result of
  Right tx -> do
    let body = tx ^. bodyTxL
    body ^. totalCollateralTxBodyL `shouldBe` SJust expectedTotal
    case body ^. collateralReturnTxBodyL of
      SJust o -> do
        o ^. addrTxOutL  `shouldBe` returnAddr
        o ^. coinTxOutL  `shouldBe` collateralIn `subtractCoin` expectedTotal
      SNothing -> expectationFailure "collateral_return missing"
```

This is the shape used in the unit tests added under `test/Cardano/Node/Client/TxBuildSpec.hs`.
