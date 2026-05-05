# Provider

::: {.module}
`Cardano.Node.Client.Provider`
:::

Protocol-agnostic interface for querying the Cardano blockchain.

```haskell
data Provider m = Provider
    { withAcquired       :: forall a. (QueryHandle m -> m a) -> m a
    , queryUTxOs         :: Addr -> m [(TxIn, TxOut ConwayEra)]
    , queryUTxOByTxIn    :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))
    , queryProtocolParams :: m (PParams ConwayEra)
    , evaluateTx         :: ConwayTx -> m (EvaluateTxResult ConwayEra)
    , posixMsToSlot      :: Integer -> m SlotNo
    , posixMsCeilSlot    :: Integer -> m SlotNo
    }
```

## Fields

| Field | Description |
|-------|-------------|
| `withAcquired` | Run several queries against one acquired ledger snapshot |
| `queryUTxOs` | Look up UTxOs at an address |
| `queryUTxOByTxIn` | Look up UTxOs by their transaction inputs |
| `queryProtocolParams` | Fetch current protocol parameters |
| `evaluateTx` | Evaluate script execution units for a transaction |
| `posixMsToSlot` | Convert POSIX milliseconds to a floor `SlotNo` |
| `posixMsCeilSlot` | Convert POSIX milliseconds to a ceiling `SlotNo` |

## Acquired Sessions

`withAcquired` gives the callback a `QueryHandle` whose query functions
share one LocalStateQuery `Acquire`. N2C-backed handles keep the node
protocol client in the acquired state until the callback returns, so all
handle queries read the same ledger snapshot.

```haskell
withAcquired provider $ \handle -> do
    pp <- queryProtocolParamsH handle
    byAddress <- queryUTxOsAtH handle requestedAddresses
    byInput <- queryUTxOByTxInH handle requestedInputs
    pure (pp, byAddress, byInput)
```

Handle functions mirror the LSQ-backed provider methods:

| Handle function | Description |
|-----------------|-------------|
| `queryUTxOsH` | Look up UTxOs at one address in the acquired snapshot |
| `queryUTxOsAtH` | Look up UTxOs at several addresses, grouped by address |
| `queryUTxOByTxInH` | Look up UTxOs by their transaction inputs |
| `queryProtocolParamsH` | Fetch protocol parameters |
| `evaluateTxH` | Evaluate script execution units |
| `posixMsToSlotH` | Convert POSIX milliseconds to a floor `SlotNo` |
| `posixMsCeilSlotH` | Convert POSIX milliseconds to a ceiling `SlotNo` |

The standalone provider methods are unchanged for callers. For N2C they
wrap `withAcquired` internally with one query, so existing call sites can
keep using `queryUTxOs`, `queryUTxOByTxIn`, `queryProtocolParams`,
`evaluateTx`, `posixMsToSlot`, and `posixMsCeilSlot`. When several
related reads must share one snapshot, prefer one explicit `withAcquired`
callback instead of several standalone calls; each standalone N2C call
opens and releases its own acquired session.

### `evaluateTx`

Evaluates Plutus script execution units for a fully-built transaction.
The implementation resolves all transaction inputs (spending, collateral,
and reference) from the node, fetches protocol parameters, system start,
and the hard-fork interpreter, then calls the ledger's `evalTxExUnits`
locally.

Returns a `Map` from each script purpose to either a
`TransactionScriptFailure` or the computed `ExUnits`.

## Constructors

| Function | Module | Transport |
|----------|--------|-----------|
| `mkN2CProvider` | `Cardano.Node.Client.N2C.Provider` | Unix socket (N2C) |

## Usage

```haskell
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)

let provider = mkN2CProvider lsqChannel

utxos  <- queryUTxOs provider myAddress
pp     <- queryProtocolParams provider
exUnits <- evaluateTx provider mySignedTx

(pp2, utxosByAddress, utxosByInput) <-
    withAcquired provider $ \handle -> do
        pp2 <- queryProtocolParamsH handle
        utxosByAddress <- queryUTxOsAtH handle myAddresses
        utxosByInput <- queryUTxOByTxInH handle myInputs
        pure (pp2, utxosByAddress, utxosByInput)
```
