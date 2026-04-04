# Implementation Plan: Chain Populator

**Branch**: `001-chain-populator` | **Date**: 2026-04-02 | **Spec**: `specs/001-chain-populator/spec.md`

## Summary

Add a `ChainPopulator` CPS state machine type and a `populateChain` runner to the devnet library. The runner connects ChainSync + LSQ + LTxS to the same devnet node, feeds slots and UTxOs to the populator, submits returned transactions, and accumulates the resulting blocks.

## Technical Context

**Language/Version**: Haskell (GHC 9.8.4)
**Library**: `cardano-node-clients:devnet` (existing public library)
**Dependencies**: cardano-node-clients (main lib), cardano-ledger-api, ouroboros-network-api
**Testing**: hspec E2E test against a real devnet

## Constitution Check

- Channel-Driven N2C Clients: yes — uses existing ChainSync + LSQ + LTxS
- Devnet E2E Testing: yes — tests run against real devnet
- Test Utilities Are First-Class: yes — exported from devnet library

## Source Code

```text
e2e-test/
└── Cardano/Node/Client/E2E/
    ├── ChainPopulator.hs   # NEW — ChainPopulator type + populateChain
    ├── Devnet.hs           # existing
    └── Setup.hs            # existing
```

## Implementation Approach

### Types

```haskell
-- CPS state machine
newtype ChainPopulator = ChainPopulator
    { onSlot
        :: SlotNo
        -> [(TxIn, TxOut ConwayEra)]
        -> IO ([Tx ConwayEra], Maybe ChainPopulator)
    }

-- Runner
populateChain
    :: FilePath                       -- socket path
    -> NetworkMagic                   -- network magic
    -> Addr                           -- address to query UTxOs for
    -> SignKeyDSIGN Ed25519DSIGN      -- signing key for submitted txs
    -> ChainPopulator                 -- initial state
    -> IO [Block]                     -- resulting chain
```

### Wiring

`populateChain` does:

1. Open LSQ + LTxS channels, start `runNodeClient` in background
2. Build `Provider` and `Submitter` from channels
3. Build a `Follower` that on each block:
   a. Queries UTxOs at the address via Provider
   b. Calls `onSlot` with the block's slot and UTxOs
   c. Signs and submits returned transactions via Submitter
   d. Accumulates the block in a list
   e. If populator returns `Nothing`, signals done
4. Connect ChainSync from origin via `runChainSyncN2C`
5. Wait for done signal, cancel ChainSync, return blocks

### Signing

The infrastructure signs each transaction with the provided key via `addKeyWitness` from Setup.hs.

### Done signal

Use a `TMVar [Block]` — when the populator returns `Nothing`, put the accumulated blocks and the ChainSync loop terminates.
