# Data Model: Provider acquired query session

## Provider

Public record containing one-shot methods plus `withAcquired`.

Fields affected:
- `withAcquired`: runs a callback with a `QueryHandle`.
- Existing fields remain one-shot convenience methods.

## QueryHandle

Opaque public type passed into `withAcquired` callbacks.

Operations:
- `queryUTxOsH :: Addr -> m [(TxIn, TxOut ConwayEra)]`
- `queryUTxOsAtH :: Set Addr -> m (Map Addr [(TxIn, TxOut ConwayEra)])`
- `queryUTxOByTxInH :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))`
- `queryProtocolParamsH :: m (PParams ConwayEra)`
- `evaluateTxH :: ConwayTx -> m (EvaluateTxResult ConwayEra)`
- `posixMsToSlotH :: Integer -> m SlotNo`
- `posixMsCeilSlotH :: Integer -> m SlotNo`

Validation:
- The handle is only valid inside the callback that received it.
- The constructor is not exported from `Cardano.Node.Client.Provider`.

## QueryHandleBackend

Named record of backend operations used by provider implementations to
construct an opaque `QueryHandle` without relying on positional
constructor arguments.

## LSQRequest

Internal request sent to the LocalStateQuery protocol client.

Variants:
- one-shot query request
- acquired-session request

## AcquiredLSQ

Internal lower-level session handle. Owns a queue of acquired-session commands.

Commands:
- query
- release
