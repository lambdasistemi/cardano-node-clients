# Balance

::: {.module}
`Cardano.Node.Client.Balance`
:::

Iterative exact-fee transaction balancing for Conway-era
transactions.

```haskell
balanceTx
    :: PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> Tx ConwayEra
    -> Either BalanceError (Tx ConwayEra)
```

## Algorithm

1. Collect all input UTxOs and compute total available ADA
2. Start with fee = 0
3. Build candidate transaction with change output
4. Compute exact fee via `getMinFeeTx`
5. Add 106-byte VKey witness padding using `ppMinFeeAL`
6. If new fee > current fee, repeat from step 3
7. Converges in at most 10 rounds

## Errors

```haskell
data BalanceError
    = InsufficientFee Coin Coin
    -- ^ required fee, available ADA
```

## Limitations

- ADA-only fee inputs (no multi-asset coin selection)
- Single key witness assumed
- Callers must construct script inputs separately
