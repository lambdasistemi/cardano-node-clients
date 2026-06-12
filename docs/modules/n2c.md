# N2C (Node-to-Client)

::: {.module}
`Cardano.Node.Client.N2C.*`
:::

Node-to-Client protocol implementation over Unix sockets.

## Connection

```haskell
runNodeClient
    :: NetworkMagic -> FilePath
    -> LSQChannel -> LTxSChannel
    -> IO (Either SomeException ())
```

Opens a multiplexed connection with two mini-protocols:

- **MiniProtocol 6** — LocalTxSubmission
- **MiniProtocol 7** — LocalStateQuery

For processes that also need ChainSync on the same physical
connection, use `runNodeClientFull`, which adds **MiniProtocol 5**
(ChainSync) and takes an `EpochSlots` and a ChainSync application:

```haskell
runNodeClientFull
    :: NetworkMagic -> EpochSlots -> FilePath
    -> N2CChainSyncApplication
    -> LSQChannel -> LTxSChannel
    -> IO (Either SomeException ())
```

Both helpers negotiate `NodeToClientV_23`. The shared codec
configuration (`Cardano.Node.Client.N2C.Codecs`) uses
`CardanoNodeToClientVersion19` with a configurable `EpochSlots`
(default 42 for devnet). Run either helper in a background thread —
it blocks until the connection closes.

## Channels

Create channels before starting the connection:

```haskell
lsqCh  <- newLSQChannel 16   -- 16-slot query queue
ltxsCh <- newLTxSChannel 16  -- 16-slot submit queue
```

## LocalStateQuery

The LSQ client batches queries in a single acquired session. Use
`queryLSQ` for a one-shot query, or `withAcquiredLSQ` /
`queryAcquiredLSQ` to run several queries against one acquired tip:

```haskell
queryLSQ :: LSQChannel -> Query Block result -> IO result
```

## LocalTxSubmission

Use `submitTxN2C` for low-level submission (it takes a consensus
`GenTx Block`), or prefer the high-level `mkN2CSubmitter`, which wraps
a Conway `ConwayTx` automatically.

```haskell
submitTxN2C
    :: LTxSChannel -> GenTx Block
    -> IO (Either (ApplyTxErr Block) ())
```

## Reconnect and readiness

For long-running followers, the `Reconnect` supervisor retries
ChainSync with full-jitter exponential backoff and gates the first
attempt on the `Probe` LSQ tip check, so chain-sync is never attached
against a node still loading its ChainDB. See
[Architecture](../architecture.md#reconnect-supervisor) and the
[utxo-indexer manual](../usage/utxo-indexer.md).
