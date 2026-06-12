# Submitter

::: {.module}
`Cardano.Node.Client.Submitter`
:::

Protocol-agnostic interface for submitting signed transactions.
`ConwayTx` is the package's alias for `Tx TopTx ConwayEra`
(`Cardano.Node.Client.Ledger`).

```haskell
data SubmitResult
    = Submitted !TxId       -- accepted into the mempool
    | Rejected !ByteString  -- rejection reason (UTF-8)

newtype Submitter m = Submitter
    { submitTx :: ConwayTx -> m SubmitResult
    }
```

## Constructors

| Function | Module | Transport |
|----------|--------|-----------|
| `mkN2CSubmitter` | `Cardano.Node.Client.N2C.Submitter` | Unix socket (N2C) |

The N2C submitter wraps the ledger `ConwayTx` into a consensus
`GenTx Block` before submission and serialises any rejection reason to
a `ByteString`.

## Usage

```haskell
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)

let submitter = mkN2CSubmitter ltxsChannel

result <- submitTx submitter signedTx
case result of
    Submitted txId  -> putStrLn $ "OK: " <> show txId
    Rejected reason -> putStrLn $ "FAIL: " <> show reason
```
