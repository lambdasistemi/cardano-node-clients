# Transaction Pattern Zoo

Concrete `TxBuild q` programs for every crucial case identified in the [survey](survey.md). Each pattern shows how the DSL handles a real-world scenario found across the 25 libraries surveyed.

## Case 1: Redeemer Index Computation

**Problem:** Redeemer index depends on sorted position of the input/policy, unknown at call time.

**How other libraries handle it:** CSL/CML auto-compute from sorted structure. Blaze does `insertSorted` + bumps. MPFS does manual `spendingIndex`. PyCardano does `_set_redeemer_index()` post-hoc.

**Our DSL:** Invisible. `spend`/`spendScript` return the index via `Peek`.

```haskell
-- User never thinks about indices
multiSpend :: TxBuild q e ()
multiSpend = do
    idx0 <- spendScript txIn1 (Modify proofs)
    idx1 <- spendScript txIn2 (Contribute ref)
    idx2 <- spendScript txIn3 (Contribute ref)
    -- idx0, idx1, idx2 are Word32 — correct sorted
    -- positions, resolved by fixpoint. The user
    -- can use them (e.g., in a datum) but doesn't
    -- have to.
    pure ()
```

## Case 2: Fee-Dependent Outputs (Conservation)

**Problem:** Output values depend on the final fee. Fee depends on Tx size. Tx size depends on outputs. Circular.

**How other libraries handle it:** Scalus iterates (20 max). Blaze iterates (10 max). MPFS has `balanceFeeLoop` with `mkOutputs(fee)` callback. Most libraries don't support this.

**Our DSL:** `peek` reads the fee. Build loop converges.

```haskell
-- From cardano-mpfs-onchain#37
conservationTx :: TxBuild CageQ CageErr ()
conservationTx = do
    (stateIn, datum) <- ctx (FindState pid tid)
    reqs <- ctx (FindReqs tid)
    let numReqs = length reqs
        totalIn = sumLovelace reqs
    spendScript stateIn (Modify proofs)
    forM_ reqs $ \(reqIn, _) ->
        spendScript reqIn (Contribute stateRef)
    -- Fee is circular — peek breaks the cycle
    Coin feeVal <- peek $ \tx ->
        let fee = tx ^. bodyTxL . feeTxBodyL
        in if fee > Coin 0
            then Ok fee
            else Iterate (Coin 0)
    let totalRefund = totalIn - feeVal - numReqs * tip
        perReq = totalRefund `div` numReqs
        leftover = totalRefund `mod` numReqs
    -- State output: locked value + tips
    payTo' scriptAddr
        (MaryValue (Coin (2_000_000 + numReqs * tip)) tokenMA)
        newStateDatum
    -- Refund outputs: depend on fee
    forM_ (zip [0 :: Int ..] reqs) $ \(i, _) ->
        payTo ownerAddr
            (inject (Coin (perReq + if i == 0 then leftover else 0)))
    collateral feeIn
    requireSignature ownerKh
    attachScript script
```

## Case 3: Deferred Redeemer (Value Depends on Final Tx)

**Problem:** A redeemer's Data depends on the final transaction — e.g., number of inputs, index of a specific output.

**How other libraries handle it:** Scalus: `redeemerBuilder: Transaction => Data`. Lucid Evolution: `RedeemerBuilder { makeRedeemer(inputIndices) }`. Most libraries don't support this.

**Our DSL:** `peek` returns any type, used via bind.

```haskell
-- Scalus pattern: redeemer counts inputs
selfReferentialSpend :: TxBuild q e ()
selfReferentialSpend = do
    spend pubKeyIn
    inputCount <- peek $ \tx ->
        Ok $ Set.size (tx ^. bodyTxL . inputsTxBodyL)
    spendScript scriptIn (CountRedeemer inputCount)
    payTo recipientAddr value
```

```haskell
-- Lucid Evolution pattern: redeemer references
-- the index where a specific input lands
indexAwareSpend :: TxBuild q e ()
indexAwareSpend = do
    myIdx <- spendScript oracleIn OracleRedeemer
    -- myIdx is the sorted index of oracleIn
    -- in the final input set. Downstream code
    -- can use it in a datum:
    payTo' outputAddr value (ProofOfIndex myIdx)
```

## Case 4: Deferred Datum (Value Depends on Final Tx)

**Problem:** An inline datum depends on the final transaction structure — e.g., "which output index am I?"

**How other libraries handle it:** Scalus: `datumBuilder: Transaction => Data`. Others: not supported.

**Our DSL:** Same mechanism as deferred redeemers — `peek`.

```haskell
-- Scalus pattern: datum contains its own output index
selfAwareDatum :: TxBuild q e ()
selfAwareDatum = do
    myOutIdx <- payTo' bobAddr value (PlaceholderDatum 0)
    -- Wait — payTo' already committed the datum.
    -- For a truly deferred datum, use output + peek:
    selfIdx <- peek $ \tx ->
        let outs = tx ^. bodyTxL . outputsTxBodyL
            idx = findIndex (\o -> getAddr o == bobAddr) outs
        in maybe (Iterate 0) Ok idx
    output $ mkBasicTxOut bobAddr value
        & datumTxOutL .~ mkInlineDatum (toPlcData (SelfDatum selfIdx))
```

Note: this is more verbose than Scalus's `payTo(addr, value, tx => datum)` because our `payTo'` commits the datum eagerly. For a deferred datum, use `output` + `peek` separately. Could add a `payToDeferred` combinator later.

## Case 5: Deferred UTxO Query (Steps Depend on Chain State)

**Problem:** Transaction steps depend on chain state only available at runtime — find a UTxO, decode its state, decide what to spend.

**How other libraries handle it:** Scalus: `Deferred(UtxoQuery, Utxos => Seq[Step])`. PyCardano: `add_input_address(addr)` defers to build. Others: must query upfront.

**Our DSL:** `ctx` with user-defined query GADT.

```haskell
-- Scalus UtxoCell pattern: find beacon, decode, transition
data CounterQ a where
    FindCell :: PolicyID -> AssetName
             -> CounterQ (TxIn, CounterState)
    FindFee  :: Addr -> CounterQ (TxIn, TxOut ConwayEra)

incrementCounter :: TxBuild CounterQ CounterErr ()
incrementCounter = do
    (cellIn, state) <- ctx (FindCell pid tokenName)
    let newState = state { count = count state + 1 }
    spendScript cellIn (Increment)
    payTo' scriptAddr cellValue newState
    (feeIn, _) <- ctx (FindFee walletAddr)
    collateral feeIn
    attachScript counterScript
```

## Case 6: Coin Selection

**Problem:** Select UTxOs from a wallet to cover outputs + fees.

**How other libraries handle it:** CSL/CML: 4 CIP-2 strategies. PyCardano: LargestFirst + RandomImproveMultiAsset. Atlas: from cardano-wallet.

**Our DSL:** Delegated to `balanceTx` (inside `build`). The user doesn't see it.

```haskell
-- User just declares what they want
simplePay :: TxBuild Void Void ()
simplePay = do
    payTo bobAddr (inject (Coin 5_000_000))
    payTo charlieAddr (inject (Coin 3_000_000))

-- build handles input selection + fee + change
result <- build pp evaluator utxos [] changeAddr simplePay
```

## Case 7: Script Evaluation (ExUnits)

**Problem:** Plutus scripts need execution budgets. Only known after running scripts against the assembled Tx.

**How other libraries handle it:** CML: two-phase `build_for_evaluation` + `set_exunits`. PyCardano: auto via ChainContext. Blaze: pluggable `useEvaluator`.

**Our DSL:** `build` takes an evaluator function. `draft` skips evaluation (placeholders).

```haskell
-- draft: for testing, no evaluation
let tx = draft pp myProgram
-- tx has ExUnits 0 0 in all redeemers

-- build: real evaluation
result <- build pp
    (evaluateTx provider)     -- evaluator
    inputUtxos changeAddr
    myProgram
-- tx has real ExUnits, balanced fee
```

## Case 8: Composability (Multiple Protocols in One Tx)

**Problem:** Compose independent protocol interactions. Each protocol knows its own patterns but not the others.

**How other libraries handle it:** Scalus: `UtxoCellDef.apply(action)` with `Deferred`. Blaze: `preCompleteHooks`. Atlas: `buildTxBodyParallel`.

**Our DSL:** Each protocol defines its query constructors. Composed via sum type.

```haskell
-- Protocol A: MPFS cage
data CageQ a where
    FindState :: PolicyID -> TokenId -> CageQ (TxIn, CageDatum)

-- Protocol B: DEX swap
data DexQ a where
    FindPool :: AssetPair -> DexQ (TxIn, PoolDatum)

-- Composed
data AppQ a where
    Cage :: CageQ a -> AppQ a
    Dex  :: DexQ a -> AppQ a

-- One transaction, two protocols
composedTx :: TxBuild AppQ AppErr ()
composedTx = do
    -- MPFS update
    (stateIn, datum) <- ctx (Cage (FindState pid tid))
    spendScript stateIn (Modify proofs)
    payTo' cageAddr stateValue newDatum

    -- DEX swap in same tx
    (poolIn, poolDatum) <- ctx (Dex (FindPool pair))
    spendScript poolIn (Swap amount)
    payTo' dexAddr poolValue newPoolDatum

    -- Shared: fee, collateral
    collateral feeIn
    attachScript cageScript
    attachScript dexScript

-- Each protocol's interpreter is independent
appInterpreter :: Provider IO -> AppQ a -> IO a
appInterpreter prov (Cage q) = cageInterpreter prov q
appInterpreter prov (Dex q)  = dexInterpreter prov q
```

## Case 9: Pay vs Lock Safety

**Problem:** Paying to a script address without a datum locks funds forever.

**How other libraries handle it:** Blaze: `lockAssets` (asserts script + datum) vs `payAssets`. Lucid: `pay.ToContract`. Others: no enforcement.

**Our DSL:** Not enforced in the core. Could add as a smart constructor:

```haskell
-- Future addition: enforced script output
lockAt
    :: ToData d
    => ScriptHash -> MaryValue -> d
    -> TxBuild q Word32
lockAt sh val datum = do
    let addr = Addr net (ScriptHashObj sh) StakeRefNull
    payTo' addr val datum

-- Using it makes the intent clear
lockAt cageScriptHash stateValue stateDatum
-- vs
payTo someAddr value  -- might be script, might not
```

## Case 10: Nested Fee Convergence

**Problem:** Two levels of iteration: `balanceTx` converges the fee, `peek` converges deferred values. They interact.

**How other libraries handle it:** Scalus: single loop (delayed redeemers resolved inside balancing). Blaze: single loop. CML: explicit two-phase. MPFS: `balanceFeeLoop` is a custom single loop.

**Our DSL:** Explicit two nested loops. The interaction is safe because:

```
Outer loop (Peek convergence):
  1. Interpret program with current Tx
     → Peek nodes see current Tx
     → Iterate/Ok determine satisfaction
  2. Assemble Tx from steps
  3. Inner loop (balanceTx fee convergence):
     a. Evaluate scripts → ExUnits
     b. Estimate fee from Tx size
     c. Adjust change output
     d. If fee changed → goto a
  4. If outer Tx changed OR any Iterate → goto 1
  5. All Ok AND Tx stable → return
```

```haskell
-- The user doesn't see the loops. They write:
myTx :: TxBuild CageQ CageErr ()
myTx = do
    fee <- peek $ \tx ->
        Ok (tx ^. bodyTxL . feeTxBodyL)
    let refund = totalIn - unCoin fee - tips
    payTo refundAddr (inject (Coin refund))
    ...

-- build handles everything
result <- build pp evaluator utxos [] changeAddr myTx
```

## Bonus: Transaction Chaining (Helios pattern)

**Problem:** Use outputs from tx1 as inputs in tx2 without submitting tx1 first.

```haskell
chainTxs :: TxBuild q e ()
chainTxs = do
    -- tx1: create a state UTxO
    outIdx <- payTo' scriptAddr value initialDatum
    -- outIdx is the output index of this output
    -- in the final tx1. A subsequent builder could
    -- reference it as TxIn(tx1Hash, outIdx).
    -- But tx1Hash isn't known until tx1 is built.
    -- This needs peek:
    tx1Id <- peek $ \tx ->
        Ok (txIdFromTx tx)
    -- Now we have (tx1Id, outIdx) — a valid TxIn
    -- for a chained tx2. But that's a different
    -- TxBuild program, not this one.
    pure ()
```

Note: true chaining (multiple txs in one program) would need `TxBuild` to support multiple transaction boundaries. Out of scope for now — each `TxBuild q a` is one transaction.

## Bonus: Metadata (TyphonJS / Mesh pattern)

**Problem:** Attach transaction metadata (auxiliary data).

```haskell
-- Not yet in our GADT. Would be:
-- SetMetadata :: Word64 -> PLC.Data -> TxInstr q ()

-- For now, use output with raw TxOut construction
-- or add to the GADT when needed.
```

## Bonus: Collateral Return (Blaze / CML pattern)

**Problem:** When collateral contains native tokens, a collateral return output is needed to get the tokens back if a script fails.

```haskell
-- Not yet in our GADT. Would be:
-- SetCollateralReturn :: TxOut ConwayEra -> TxInstr q ()

-- For now, the balancer could handle this
-- automatically when collateral has tokens.
```

## Summary

| Pattern | Mechanism | Lines of user code |
|---------|-----------|-------------------|
| Redeemer indices | `spend`/`spendScript` return `Word32` | 0 (automatic) |
| Fee-dependent outputs | `peek` reads fee | 3-4 |
| Deferred redeemer | `peek` + bind | 2-3 |
| Deferred datum | `peek` + `output` | 3-4 |
| UTxO queries | `ctx` | 1 per query |
| Coin selection | `build` internally | 0 (automatic) |
| Script evaluation | `build` internally | 0 (automatic) |
| Composability | Sum-type `q` | natural |
| Pay vs Lock | `lockAt` (future) | 1 |
| Fee convergence | `build` loop | 0 (automatic) |
