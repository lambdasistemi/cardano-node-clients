# Provider

::: {.module}
`Cardano.Node.Client.Provider`
:::

Protocol-agnostic interface for querying the Cardano blockchain. All
era-specific types are fixed to `ConwayEra`.

```haskell
data Provider m = Provider
    { withAcquired        :: forall a. (QueryHandle m -> m a) -> m a
    , queryUTxOs          :: Addr -> m [(TxIn, TxOut ConwayEra)]
    , queryUTxOByTxIn     :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))
    , queryProtocolParams :: m (PParams ConwayEra)
    , queryLedgerSnapshot :: m LedgerSnapshot
    , queryStakeRewards   :: Set (Credential Staking)
                          -> m (Map (Credential Staking) Coin)
    , queryRewardAccounts :: Set AccountAddress
                          -> m (Map AccountAddress Coin)
    , queryVoteDelegatees :: Set (Credential Staking)
                          -> m (Map (Credential Staking) DRep)
    , queryTreasury       :: m Coin
    , queryGovernanceState :: m (GovState ConwayEra)
    , evaluateTx          :: ConwayTx -> m (EvaluateTxResult ConwayEra)
    , posixMsToSlot       :: Integer -> m SlotNo
    , posixMsCeilSlot     :: Integer -> m SlotNo
    , queryUpperBoundSlot :: ValidityChoice
                          -> m (Either HorizonError SlotNo)
    }
```

## Fields

| Field | Description |
|-------|-------------|
| `withAcquired` | Run several queries against one acquired ledger snapshot |
| `queryUTxOs` | Look up UTxOs at an address |
| `queryUTxOByTxIn` | Look up unspent UTxOs by their `TxIn` at the tip |
| `queryProtocolParams` | Fetch current protocol parameters |
| `queryLedgerSnapshot` | Fetch current era, chain point, tip slot, and epoch |
| `queryStakeRewards` | Reward balances for stake credentials |
| `queryRewardAccounts` | Reward balances by reward account |
| `queryVoteDelegatees` | Conway vote delegatees for stake credentials |
| `queryTreasury` | Current treasury value |
| `queryGovernanceState` | Conway governance state |
| `evaluateTx` | Evaluate script execution units for a transaction |
| `posixMsToSlot` | Convert POSIX milliseconds to a floor `SlotNo` |
| `posixMsCeilSlot` | Convert POSIX milliseconds to a ceiling `SlotNo` |
| `queryUpperBoundSlot` | Horizon-aware `invalid-hereafter` slot ([Validity](validity.md)) |

## Acquired sessions

`withAcquired` gives the callback a `QueryHandle` whose query functions
share one LocalStateQuery `Acquire`. N2C-backed handles keep the node
protocol client in the acquired state until the callback returns, so
all handle queries read the same ledger snapshot.

```haskell
withAcquired provider $ \handle -> do
    pp        <- queryProtocolParamsH handle
    byAddress <- queryUTxOsAtH handle requestedAddresses
    byInput   <- queryUTxOByTxInH handle requestedInputs
    pure (pp, byAddress, byInput)
```

Handle functions mirror the standalone provider methods with an `H`
suffix:

| Handle function | Description |
|-----------------|-------------|
| `queryUTxOsH` | UTxOs at one address in the acquired snapshot |
| `queryUTxOsAtH` | UTxOs at several addresses, grouped by address |
| `queryUTxOByTxInH` | UTxOs by their `TxIn` |
| `queryProtocolParamsH` | Protocol parameters |
| `queryLedgerSnapshotH` | Era, chain point, tip slot, epoch |
| `queryStakeRewardsH` | Reward balances for stake credentials |
| `queryRewardAccountsH` | Reward balances by reward account |
| `queryVoteDelegateesH` | Vote delegatees for stake credentials |
| `queryTreasuryH` | Treasury value |
| `queryGovernanceStateH` | Conway governance state |
| `evaluateTxH` | Evaluate script execution units |
| `posixMsToSlotH` | POSIX milliseconds to a floor `SlotNo` |
| `posixMsCeilSlotH` | POSIX milliseconds to a ceiling `SlotNo` |

The standalone provider methods are unchanged for callers. For N2C
they wrap `withAcquired` internally with a single query, so each
standalone call opens and releases its own acquired session. When
several related reads must share one snapshot, prefer one explicit
`withAcquired` callback.

### `evaluateTx`

Evaluates Plutus script execution units for a fully-built transaction.
The implementation resolves all transaction inputs (spending,
collateral, and reference) from the node, fetches protocol parameters,
system start, and the hard-fork interpreter, then calls the ledger's
`evalTxExUnits` locally.

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

utxos   <- queryUTxOs provider myAddress
pp      <- queryProtocolParams provider
exUnits <- evaluateTx provider mySignedTx

(pp2, utxosByAddress, utxosByInput) <-
    withAcquired provider $ \handle -> do
        pp2            <- queryProtocolParamsH handle
        utxosByAddress <- queryUTxOsAtH handle myAddresses
        utxosByInput   <- queryUTxOByTxInH handle myInputs
        pure (pp2, utxosByAddress, utxosByInput)
```
