# Contract: `Provider IO` extension

**Module**: `Cardano.Node.Client.Provider` (`lib/Cardano/Node/Client/Provider.hs`)

This feature adds one method to the existing `Provider` record. Existing
methods are unchanged.

## Before

```haskell
data Provider m = Provider
    { queryUTxOs           :: Addr -> m [(TxIn, TxOut ConwayEra)]
    , queryProtocolParams  :: m (PParams ConwayEra)
    , evaluateTx           :: ConwayTx -> m (EvaluateTxResult ConwayEra)
    , posixMsToSlot        :: Integer -> m SlotNo
    , posixMsCeilSlot      :: Integer -> m SlotNo
    }
```

## After

```haskell
data Provider m = Provider
    { queryUTxOs           :: Addr -> m [(TxIn, TxOut ConwayEra)]
    , queryUTxOByTxIn      :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))
    , queryProtocolParams  :: m (PParams ConwayEra)
    , evaluateTx           :: ConwayTx -> m (EvaluateTxResult ConwayEra)
    , posixMsToSlot        :: Integer -> m SlotNo
    , posixMsCeilSlot      :: Integer -> m SlotNo
    }
```

### Semantics

- **Input**: the set of `TxIn`s to look up at the current chain tip.
- **Output**: a `Map` containing only those inputs found in the tip UTxO set.
  Missing entries indicate the input is spent or rolled past.
- **Round trips**: exactly 1 LSQ query per call.
- **Failure**: if the LSQ channel is unavailable, raises `ConnectionLost`
  (`Cardano.Node.Client.N2C.Types.ConnectionLost`). Callers catch this
  exception via the existing arm-level `E.handle`.

### N2C implementation

`lib/Cardano/Node/Client/N2C/Provider.hs` will add:

```haskell
queryUTxOByTxIn = \txins -> do
    result <- queryLSQ ch $
        BlockQuery $ QueryIfCurrentConway $ GetUTxOByTxIn txins
    case result of
        QueryResultSuccess utxo -> pure (unUTxO utxo)
        QueryResultEraMismatch _ -> throwIO ConnectionLost  -- or a new dedicated error; matches existing pattern
```

`pattern GetUTxOByTxIn` is already imported (`N2C/Provider.hs:66`).

### Test stubs

Test stubs of `Provider` (e.g. in `SelectionSpec`) gain a `queryUTxOByTxIn`
field returning a fixed `Map`. Existing stubs are extended; no breaking
change to test signatures.

## Helper

```haskell
-- | Lives in Cardano.Node.Client.TxGenerator.Selection (or a new
--   Submit module if it grows further).
verifyInputsUnspent :: Provider IO -> Set TxIn -> IO Bool
verifyInputsUnspent p inputs = do
    found <- queryUTxOByTxIn p inputs
    pure (Map.keysSet found == inputs)
```

Returns `True` iff every queried input is still unspent. Raises
`ConnectionLost` on LSQ unavailability (propagated to caller's
`E.handle`).

## Call sites

- `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:603` (refill, `buildSignSubmit`)
  — call `verifyInputsUnspent` between `addKeyWitness` and `submitTx`.
- `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:845` (transact,
  `transactWithSource`) — same pattern.

On `False`, the arm returns `RefillFail IndexNotReady` /
`TransactFail IndexNotReady`. No new constructor in `FailureReason`.
