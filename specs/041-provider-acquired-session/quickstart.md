# Quickstart: Provider acquired query session

## One-shot usage remains unchanged

```haskell
let provider = mkN2CProvider lsq

pp <- queryProtocolParams provider
utxos <- queryUTxOs provider genesisAddr
```

Each standalone N2C call opens and releases its own acquired session.
Use `withAcquired` when several related reads need one shared snapshot.

## Acquired-session usage

```haskell
withAcquired provider $ \handle -> do
    pp <- queryProtocolParamsH handle
    byAddr <- queryUTxOsAtH handle (Set.singleton registryAddr)
    byTxIn <- queryUTxOByTxInH handle referencedTxIns
    pure (pp, byAddr, byTxIn)
```

All queries in the callback are served by one LocalStateQuery acquire/release cycle.

## Verification

```bash
nix develop --quiet -c just ci
```
