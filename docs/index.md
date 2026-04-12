# cardano-node-clients

Channel-driven Haskell clients for Cardano node Ouroboros mini-protocols.

## Overview

This library provides high-level interfaces for communicating with a
Cardano node:

- **Provider** -- query UTxOs and protocol parameters
- **Submitter** -- submit signed transactions
- **Balance** -- exact-fee balancing and fee-dependent output convergence
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

- spending, script spending, outputs, collateral, minting, required
  signers, attached scripts, reference inputs, and validity intervals
- `Peek`-driven fixpoint values for indices and fee-dependent assembly
- pure drafting with `draft` and `draftWith`
- effectful building with `build` and `InterpretIO`
- pluggable context queries through `Ctx`
- opt-in final-transaction validation via `Valid`
- balancing with eval retry, fee oscillation handling, bisection, and
  final `maxFee` re-iteration

## Testing

- Unit tests cover exact `getMinFeeTx` balancing, eval retry,
  oscillation handling, `bumpFee`, and the `TxBuild` instruction set.
- E2E tests run against a real devnet for provider, `balanceFeeLoop`,
  chainsync, chain population, and a submitted `TxBuild` transaction
  that exercises `spend`, `payTo`, `payTo'`, `ctx`, `peek`, `valid`,
  `requireSignature`, and `validFrom`/`validTo`.

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
