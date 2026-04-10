# Data Model: Transaction Builder DSL

## TxBuilder

Immutable accumulator. Each combinator appends a step and returns a new value.

- **steps**: ordered list of TxStep
- **scripts**: map from ScriptHash to Script (attached scripts)

## TxStep (sum type)

- **Spend**: TxIn + SpendWitness
- **ReferenceOutput**: TxIn
- **AddCollateral**: TxIn
- **Send**: TxOut ConwayEra
- **Mint**: PolicyID + AssetName + Integer + MintWitness
- **ValidityStart**: SlotNo
- **ValidityEnd**: SlotNo
- **RequireSignature**: KeyHash 'Witness

## SpendWitness (sum type)

- **PubKeyWitness**: no additional data
- **ScriptWitness**: existential `r` with `ToData r` constraint — the typed redeemer

## MintWitness

- **PlutusScriptWitness**: existential `r` with `ToData r` constraint — the typed redeemer

## State Transitions

```
txBuilder (empty)
  → spend/spendScript/references/collaterals/payTo/mint/validFrom/validTo/requireSignature (accumulate steps)
    → build (assemble + evaluate + balance → Tx ConwayEra)
    → complete (query UTxOs + build → Tx ConwayEra)
    → draft (assemble only → Tx ConwayEra)
```

## Relationships to Existing Types

- TxBuilder produces `Tx ConwayEra` (cardano-ledger)
- `build` consumes `Provider IO` (cardano-mpfs-offchain) and `PParams ConwayEra` (cardano-ledger)
- `build` delegates to `balanceTx` (cardano-node-clients)
- SpendWitness/MintWitness use `ToData` from plutus-tx
