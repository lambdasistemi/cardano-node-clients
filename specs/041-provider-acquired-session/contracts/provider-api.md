# Contract: Provider acquired-session API

**Module**: `Cardano.Node.Client.Provider`

## New API

```haskell
data QueryHandle m

data QueryHandleBackend m

mkQueryHandle
    :: QueryHandleBackend m
    -> QueryHandle m

withAcquired
    :: Provider m
    -> (QueryHandle m -> m a)
    -> m a

queryUTxOsAtH
    :: QueryHandle m
    -> Set Addr
    -> m (Map Addr [(TxIn, TxOut ConwayEra)])

queryUTxOByTxInH
    :: QueryHandle m
    -> Set TxIn
    -> m (Map TxIn (TxOut ConwayEra))

queryProtocolParamsH
    :: QueryHandle m
    -> m (PParams ConwayEra)

evaluateTxH
    :: QueryHandle m
    -> ConwayTx
    -> m (EvaluateTxResult ConwayEra)

posixMsToSlotH
    :: QueryHandle m
    -> Integer
    -> m SlotNo

posixMsCeilSlotH
    :: QueryHandle m
    -> Integer
    -> m SlotNo
```

## Compatibility

Existing one-shot fields remain:

```haskell
queryUTxOs :: Provider m -> Addr -> m [(TxIn, TxOut ConwayEra)]
queryUTxOByTxIn :: Provider m -> Set TxIn -> m (Map TxIn (TxOut ConwayEra))
queryProtocolParams :: Provider m -> m (PParams ConwayEra)
evaluateTx :: Provider m -> ConwayTx -> m (EvaluateTxResult ConwayEra)
posixMsToSlot :: Provider m -> Integer -> m SlotNo
posixMsCeilSlot :: Provider m -> Integer -> m SlotNo
```

## Semantics

- `withAcquired` brackets an LSQ acquire/release in N2C-backed providers.
- `QueryHandle` methods are valid only during the callback.
- Existing one-shot fields still perform their own bracketed acquire/release cycle.
- Several related N2C reads should use one explicit `withAcquired` callback rather than several one-shot fields when they need one shared snapshot.
