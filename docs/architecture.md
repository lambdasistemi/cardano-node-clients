# Architecture

## Design

The library separates **protocol-agnostic interfaces** from
**protocol-specific implementations**.

```
cardano-node-clients:tx-build
├── Ledger         -- ConwayTx alias
├── Balance        -- transaction balancing
└── TxBuild        -- transaction builder DSL

cardano-node-clients
├── Types          -- Block, BlockPoint aliases
├── Provider       -- query interface (record-of-functions)
├── Submitter      -- submit interface (record-of-functions)
├── Balance        -- re-export from tx-build
├── TxBuild        -- re-export from tx-build
└── N2C
    ├── Types              -- LSQChannel, LTxSChannel
    ├── Codecs             -- N2C codec config
    ├── Connection         -- multiplexed Unix socket
    ├── LocalStateQuery    -- LSQ protocol client
    ├── LocalTxSubmission  -- LTxS protocol client
    ├── Provider           -- N2C-backed Provider
    └── Submitter          -- N2C-backed Submitter
```

## Channel-driven protocol clients

Each mini-protocol client is driven by an STM channel (`TBQueue`).
Callers enqueue a request and block on a `TMVar` for the result.
This decouples request submission from the Ouroboros protocol loop.

```
                  ┌───────────────┐
  caller ──req──► │   TBQueue     │ ──► protocol client ──► node
  caller ◄─res──  │   TMVar       │ ◄── protocol client ◄── node
                  └───────────────┘
```

The **LocalStateQuery** client batches queries: it waits for the
first query, acquires the volatile tip, drains the queue in a
single session, then releases and loops.

## N2C connection

`runNodeClient` opens a Unix socket to the Cardano node and
multiplexes two mini-protocols:

- **MiniProtocol 6** -- LocalTxSubmission
- **MiniProtocol 7** -- LocalStateQuery

The connection blocks until closed. Run it in a background thread
with `async`.

## Transaction balancing

`Cardano.Node.Client.Balance` is implemented by the public
`cardano-node-clients:tx-build` sublibrary and re-exported by the main
library for compatibility. It has no node-communication, indexer,
daemon, socket, or RocksDB dependency.

`balanceTx` iteratively computes the exact ledger fee with
`getMinFeeTx`, then adds VKey witness padding for the unsigned
transaction before adding fee-paying inputs and a change output.
It converges in at most 10 rounds. Only ADA-only inputs are
supported; multi-asset coin selection is out of scope.

## Transaction builder DSL

`Cardano.Node.Client.TxBuild` sits one layer above raw transaction
assembly. It lives in `cardano-node-clients:tx-build`, and the main
library re-exports the same module for existing import paths. The
builder accepts a caller-supplied script evaluator, so the extracted
component does not need Provider, N2C, ChainSync, indexer, devnet, or
RocksDB dependencies.

Current implemented pieces:

- fixed transaction instructions for spends, outputs, collateral,
  minting, required signers, and attached scripts
- `Peek` for fixpoint values derived from the assembled transaction
- `Ctx` for pluggable domain queries resolved by `Interpret` or
  `InterpretIO`
- `Valid` for opt-in post-convergence transaction checks
- reference inputs and explicit validity intervals in the assembled
  `TxBody`
- `draft` and `draftWith` for pure assembly
- `build` for script evaluation, `ExUnits` patching, and balancing
