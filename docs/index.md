# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols.

## Overview

This library provides high-level interfaces for communicating with a
Cardano node:

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **Balance** -- iterative fee estimation and transaction balancing
- **TxBuild** -- Conway-era transaction builder DSL with `Peek` fixpoints and pluggable `Ctx` queries

The interfaces are protocol-agnostic records-of-functions. Each transport
protocol supplies its own constructor:

| Protocol | Provider | Submitter |
|----------|----------|-----------|
| N2C (Unix socket) | `mkN2CProvider` | `mkN2CSubmitter` |
| N2N (TCP) | planned | planned |

## Current TxBuild status

The transaction builder DSL is under active development and currently
implements the first complete branch scope:

- spending, outputs, collateral, and minting combinators
- `Peek`-driven fixpoint values for indices and fee-dependent assembly
- pure drafting with `draft` and `draftWith`
- effectful building with `build` and `InterpretIO`
- pluggable context queries through `Ctx`
- opt-in final-transaction validation via `Valid`
- reference inputs and explicit validity intervals

## Quick start

```haskell
import Cardano.Node.Client.N2C.Connection
import Cardano.Node.Client.N2C.Provider
import Cardano.Node.Client.N2C.Submitter
import Control.Concurrent.Async (async)
import Ouroboros.Network.Magic (NetworkMagic (..))

main :: IO ()
main = do
    lsqCh  <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    -- connect in background
    _ <- async $
        runNodeClient
            (NetworkMagic 764824073)  -- mainnet
            "/run/cardano-node/node.socket"
            lsqCh
            ltxsCh
    let provider  = mkN2CProvider lsqCh
        submitter = mkN2CSubmitter ltxsCh
    -- use provider / submitter ...
    pure ()
```

## Build

```bash
nix develop -c just build   # compile
nix develop -c just ci      # format + lint + build
```
