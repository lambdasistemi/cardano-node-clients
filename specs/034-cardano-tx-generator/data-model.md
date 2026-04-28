# Data Model — cardano-tx-generator

Entities derived from the spec, with concrete Haskell shapes
mapped onto in-tree types where they exist.

## Persistent state (on disk under `--state-dir`)

| File | Bytes | Lifecycle | Shape |
|---|---|---|---|
| `master.seed` | 32 | written once at bootstrap, read-only thereafter | raw bytes |
| `next-hd-index` | small text | atomically rewritten after each successful trigger | decimal `Word64` |

Atomic write: `tempfile + fsync + rename`. The `next-hd-index` write
is the durability boundary for FR-003 / FR-016.

## In-process state

```haskell
data Daemon = Daemon
  { daemonMasterSeed   :: !ByteString          -- 32 bytes; never logged
  , daemonStateDir     :: !FilePath
  , daemonNextHDIndex  :: !(MVar Word64)       -- serialises FR-016
  , daemonIndexer      :: !IndexerHandle       -- from utxo-indexer-lib
  , daemonLTxS         :: !LTxSChannel         -- from N2C.Connection
  , daemonLSQ          :: !LSQChannel          -- from N2C.Connection
  , daemonPParams      :: !(PParams ConwayEra) -- queried once at startup (D4)
  , daemonNetworkId    :: !Network             -- Testnet / Mainnet
  , daemonFaucetSKey   :: !(SignKeyDSIGN Ed25519DSIGN)
  , daemonFaucetAddr   :: !Addr
  , daemonReadyVar     :: !(TVar ReadyStatus)  -- mirrors indexer's
  , daemonLastTxIdVar  :: !(TVar (Maybe TxId))
  }
```

## Population

A virtual entity. The daemon never enumerates the population; it
derives addresses on demand.

```haskell
populationSize :: Daemon -> IO Word64
populationSize d = readMVar (daemonNextHDIndex d)

deriveSignKey :: ByteString -> Word64 -> SignKeyDSIGN Ed25519DSIGN
deriveSignKey masterSeed i =
    mkSignKey
      (BS.take 32 (blake2b256 (masterSeed <> encodeWord64 i)))

deriveAddr :: Network -> ByteString -> Word64 -> Addr
deriveAddr net masterSeed i =
    enterpriseAddr net (keyHashFromSignKey (deriveSignKey masterSeed i))
```

`mkSignKey`, `keyHashFromSignKey`, `enterpriseAddr` are all already
exposed by `Cardano.Node.Client.E2E.Setup` (E2E/Setup.hs:150–172).
The new wrapper lives in `lib/Cardano/Node/Client/TxGenerator/Population.hs`.

## Source UTxO

```haskell
data PickedSource = PickedSource
  { psIndex   :: !Word64       -- HD index that owns this UTxO
  , psSignKey :: !(SignKeyDSIGN Ed25519DSIGN)
  , psAddr    :: !Addr
  , psTxIn    :: !TxIn         -- the chosen UTxO at psAddr
  , psValue   :: !MaryValue    -- value at psTxIn
  }
```

Selection (`Cardano.Node.Client.TxGenerator.Selection`):

```haskell
pickSource
  :: IndexerHandle
  -> ByteString                          -- master seed
  -> Network
  -> Word64                              -- nextHDIndex (current)
  -> Coin                                -- minUTxO
  -> Word64                              -- K
  -> Coin                                -- fee estimate
  -> Word32                              -- maxRetries
  -> StdGen
  -> IO (Either NotApplicable PickedSource)
```

Exhaustively retries on `mkStdGen seed` chain; `Left` on cap. The
viability floor is `K * minUTxO + fee + minUTxO_for_change`.

## Destinations

```haskell
data Destination = Destination
  { dstIndex :: !Word64
  , dstAddr  :: !Addr
  , dstValue :: !Coin
  , dstFresh :: !Bool            -- true if dstIndex was newly minted
  }

pickDestinations
  :: ByteString                  -- master seed
  -> Network
  -> Word64                      -- current nextHDIndex (input)
  -> Word64                      -- K
  -> Double                      -- prob_fresh
  -> Coin                        -- available value (psValue - fee - change)
  -> Coin                        -- minUTxO
  -> StdGen                      -- consumed
  -> ([Destination], Word64)     -- destinations, new nextHDIndex
```

## Transaction shape (per `transact`)

Input:  one `TxIn` from `psAddr`.
Output: K `payTo` to destination addresses + change to `psAddr`.
Fee:    `BalanceResult` from `Balance.balanceTx`.
Wits:   one `addKeyWitness psSignKey`.

`changeIndex :: Int` (from `BalanceResult`) plus `txid balancedTx`
gives the await target `TxIn = (txid, changeIndex)`.

## Refill request

```haskell
data RefillResult = RefillResult
  { rrTxId       :: !TxId
  , rrFreshIndex :: !Word64
  , rrFreshAddr  :: !Addr
  , rrAwaited    :: !Bool
  }

runRefill
  :: Daemon
  -> Word64                      -- request seed
  -> IO (Either RefillFailure RefillResult)
```

Implementation: pick a faucet UTxO (the highest-value one observed
by the indexer), build `payTo freshAddr (faucetUtxoValue - fee)`,
sign with `daemonFaucetSKey`, submit, await `(txid, 0)` (single
output), bump `nextHDIndex`.

## Snapshot

```haskell
data Snapshot = Snapshot
  { snPopulationSize :: !Word64
  , snP10            :: !Coin
  , snP50            :: !Coin
  , snP90            :: !Coin
  , snTipSlot        :: !(Maybe SlotNo)
  , snLastTxId       :: !(Maybe TxId)
  }
```

Computation: read `nextHDIndex`; for each `i ∈ [0, nextHDIndex)`
ask the indexer for `snapshotAt addr_i`; flatten to `[Coin]` of
output values; sort and pick percentiles; tip slot from
`daemonReadyVar`; last txid from `daemonLastTxIdVar`.

The full enumeration is bounded by population size and is only
fired by the validator scripts a handful of times per run, so
linear cost is acceptable. If profiling shows otherwise, a
running-aggregate cache is a bounded follow-up.

## Ready

Mirrors the indexer's `ReadyStatus` plus `faucetUtxosKnown`:

```haskell
data ReadyResponse = ReadyResponse
  { rrReady           :: !Bool
  , rrIndexReady      :: !Bool       -- from daemonReadyVar.rsReady
  , rrFaucetUtxosKnown :: !Bool      -- snapshotAt daemonFaucetAddr is non-empty
  }
```

`rrReady = rrIndexReady && rrFaucetUtxosKnown`.

## Failure categories (FR-015)

```haskell
data Failure
  = NoPickableSource
  | IndexNotReady
  | FaucetExhausted
  | SubmitRejected !Text         -- ledger error message
```

Wire encoding in `contracts/control-wire.md`.
