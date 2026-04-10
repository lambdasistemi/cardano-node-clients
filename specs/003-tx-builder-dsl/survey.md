# Cardano Transaction Builder Survey

A cross-language survey of transaction builder patterns across the Cardano ecosystem. Focused on crucial design cases relevant to the `cardano-node-clients` TxBuild DSL.

## Libraries Surveyed

### Haskell / Scala / Java
| Library | Repo | Status |
|---------|------|--------|
| cardano-api | IntersectMBO/cardano-api | Active, canonical |
| cardano-ledger-api | IntersectMBO/cardano-ledger | Active, low-level |
| Atlas (GeniusYield) | GeniusYield/atlas | Active, highest-level Haskell |
| cooked-validators | Tweag/cooked-validators | Active, testing-focused |
| Convex / sc-tools | j-mueller/sc-tools | Active, combinator-based |
| Kuber | dQuadrant/kuber | Active, JSON-API-based |
| cardano-node-emulator | IntersectMBO/cardano-node-emulator | Maintained, slowing |
| cardano-balance-tx | cardano-foundation/cardano-balance-tx | New (Feb 2026), ledger-native |
| hydra-cardano-api | cardano-scaling/hydra | Active, Hydra-specific wrapper |
| cardano-wallet | cardano-foundation/cardano-wallet | Active, wallet-level balancing |
| Scalus (Scala/JVM) | nau/scalus | Active, most complete builder |
| cardano-client-lib (Java) | bloxbean/cardano-client-lib | Active, Java production |

### TypeScript/JavaScript
| Library | Repo | Status |
|---------|------|--------|
| Lucid Evolution | anastasia-labs/lucid-evolution | Active, production |
| Blaze | butaneprotocol/blaze-cardano | Active |
| Mesh SDK | MeshJS/mesh | Active, multi-backend |
| cardano-js-sdk | input-output-hk/cardano-js-sdk | Active, IOG/Lace wallet |
| Buildooor | HarmonicLabs/buildooor | Active, Plu-ts ecosystem |
| TyphonJS | StricaHQ/typhonjs | Active, Typhon wallet |
| Helios tx-utils | HeliosLang/tx-utils | Active, modular |
| Lucid (original) | spacebudz/lucid | Archived |

### PureScript
| Library | Repo | Status |
|---------|------|--------|
| CTL | Plutonomicon/cardano-transaction-lib | Active, constraint-based |

### Rust
| Library | Repo | Status |
|---------|------|--------|
| cardano-serialization-lib (CSL) | Emurgo/cardano-serialization-lib | Production, battle-tested |
| cardano-multiplatform-lib (CML) | dcSpark/cardano-multiplatform-lib | Production, deferred redeemers |
| Pallas txbuilder | txpipe/pallas | Early, minimal |
| Whisky | sidan-lab/whisky | Active, Mesh-compatible |

### Python
| Library | Repo | Status |
|---------|------|--------|
| PyCardano | Python-Cardano/pycardano | Production, most automated |

### Go
| Library | Repo | Status |
|---------|------|--------|
| cardano-go | echovl/cardano-go | Proof-of-concept, no Plutus |
| go-cardano-serialization | fivebinaries/go-cardano-serialization | Has golden tests |
| Rum | sidan-lab/rum | Active, Mesh-compatible |

### C#/.NET
| Library | Repo | Status |
|---------|------|--------|
| CardanoSharp | CardanoSharp/cardanosharp-wallet | Production |

---

## Crucial Cases

### Case 1: Redeemer Index Computation

**The problem:** Cardano requires redeemers to carry the index of their target in the *sorted* input or policy set. The index isn't known until all inputs are collected.

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | Computed at build time from sorted input/policy sets |
| **Lucid Evolution** | Delegated to CML which handles it internally |
| **Blaze** | Manual `insertSorted` + bump existing indices at insertion time |
| **CSL/CML** | Auto-computed from `TxInputsBuilder`'s sorted structure |
| **PyCardano** | `_set_redeemer_index()` post-hoc before build |
| **CardanoSharp** | `SetIndex(tx, scriptInput)` sorts and finds position |
| **Pallas** | Computed at build time from sorted `HashMap` keys |
| **MPFS (current)** | Manual `spendingIndex` per input |
| **Our DSL** | Auto-computed by interpreter + returned via `WithFinalTx` fixpoint |

**Crucial insight:** Every library does this automatically except raw ledger APIs. The DSL must absorb this completely — the user should never think about indices.

### Case 2: Fee-Dependent Outputs (Conservation)

**The problem:** Some transactions have outputs whose values depend on the final fee. Example: MPFS refund outputs where `refund = totalInput - fee - tips`. The fee depends on tx size, which depends on outputs, which depend on fee.

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | Iterative balancing loop (max 20 iterations) |
| **Blaze** | Iterative loop (max 10 iterations) until `lastFee === fee` |
| **CSL/CML** | Single-pass — no support for fee-dependent outputs |
| **PyCardano** | Two-pass: estimate fee → compute changes → precise fee |
| **Lucid Evolution** | Two-pass via CML |
| **cardano-js-sdk** | Input selection constraints loop |
| **MPFS onchain#37** | Custom `balanceFeeLoop` with `mkOutputs(fee)` callback |
| **Our DSL** | `WithFinalTx` reads fee from fixpoint, build loop converges |

**Crucial insight:** This is rare but critical. Most libraries don't support it. Scalus and Blaze iterate. Our `WithFinalTx` is the most general — the user writes `fee <- withFinalTx (^. feeTxBodyL)` and computes outputs from it. The loop handles convergence.

### Case 3: Deferred Redeemer (Value Depends on Final Tx)

**The problem:** A redeemer's Data value depends on the assembled transaction — e.g., "the number of inputs" or "the index of a specific output."

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | `redeemerBuilder: Transaction => Data` — resolved after assembly, before balancing |
| **Lucid Evolution** | `RedeemerBuilder { makeRedeemer: (inputIndices: bigint[]) => Redeemer }` — resolved after coin selection |
| **Blaze** | `preCompleteHooks` — callbacks before finalization |
| **cardano-js-sdk** | `customize(cb)` — modify body before input selection |
| **CSL/CML** | Not supported |
| **PyCardano** | Not supported |
| **CardanoSharp** | Not supported |
| **Our DSL** | `WithFinalTx :: (Tx ConwayEra -> a) -> TxInstr q a` — general, returns any type, resolved by fixpoint |

**All known deferred patterns across the ecosystem:**

| Library | Mechanism | What it sees | What it produces |
|---------|-----------|-------------|-----------------|
| Scalus | `redeemerBuilder: Transaction => Data` | Final Tx | Data only |
| Scalus | `datumBuilder: Transaction => Data` | Final Tx | Data only |
| Lucid Evolution | `RedeemerBuilder { makeRedeemer(indices) }` | Input indices after coin selection | Redeemer CBOR |
| Blaze | `addPreCompleteHook(tx => Promise<void>)` | Mutable builder before finalization | Side effects on builder |
| cardano-js-sdk | `customize(cb)` | Tx body before input selection | Modified tx body |
| cardano-js-sdk | Lazy `build()` | Everything deferred | `UnwitnessedTx` |
| CML | `build_for_evaluation()` + `set_exunits()` | Draft tx | ExUnits patching |
| Buildooor | `CanResolveToUTxO` | UTxO resolution at build time | Resolved UTxOs |
| CTL | Constraint-based balancing | Constraints, not concrete steps | Balanced tx |
| **Our DSL** | `WithFinalTx :: (Tx -> a) -> TxInstr q a` | Final balanced Tx (fixpoint) | **Any type** (bound via >>=) |
| **Our DSL** | `Ctx :: q a -> TxInstr q a` | Pluggable context | **Any type** (user-defined `q`) |

**Crucial insight:** Every library has invented its own ad-hoc deferred mechanism. None of them are general. Ours is the only one where (a) the deferred value can be any type, (b) it's bound via monadic `>>=`, and (c) the context is pluggable via a type parameter.

### Case 4: Deferred UTxO Queries (Steps Depend on Chain State)

**The problem:** The transaction steps themselves depend on chain state that's only available at submission time — e.g., "find the UTxO with my beacon token, decode its state, decide what to spend."

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | `Deferred(query: UtxoQuery, resolve: Utxos => Seq[Step])` with declarative query DSL |
| **PyCardano** | `add_input_address(addr)` defers UTxO selection to build time |
| **cardano-js-sdk** | Lazy `build()` defers everything |
| **Lucid Evolution** | No — must query before building |
| **Blaze** | No — must query before building |
| **CSL/CML** | No |
| **Our DSL** | `Ctx :: q a -> TxInstr q a` — pluggable context, user defines query GADT |

**Crucial insight:** Only Scalus has a structured deferred query system. Our `Ctx` is more general — the query type `q` is user-defined, and the interpreter is pluggable (`DMap q Identity` for tests, `forall x. q x -> IO x` for production). This enables composable protocol interactions (Scalus's UtxoCell pattern).

### Case 5: Datum Handling (Inline vs Hash)

**The problem:** Outputs can carry data as inline datums (V2+) or datum hashes (V1). Script spends may need the datum provided in the witness set (hash case) or can read it from the UTxO (inline case).

**Approaches:**

| Library | How outputs carry data | How script spends resolve data |
|---------|----------------------|-------------------------------|
| **Scalus** | `payTo(addr, value, datum)` — inline. `payTo(addr, value, datumHash)` — hash | Auto from inline; manual `attach()` for hash |
| **Lucid Evolution** | Three modes: `hash`, `asHash`, `inline` via `OutputDatum` | Auto-detect: inline → `plutus_script_inline_datum`; hash → needs explicit datum |
| **Blaze** | `lockAssets(addr, value, datum)` — always inline | Auto from inline; pass `unhashDatum` for hash case |
| **PyCardano** | `TransactionOutput(datum=)` inline, `datum_hash=` for hash | `add_script_input(datum=)` auto-hashes |
| **CSL/CML** | `OutputDatum` enum: inline or hash | Part of `PlutusWitness` |
| **CardanoSharp** | `DatumOption` on `AddOutput` | Manual datum witness |
| **MPFS** | Always inline (`mkInlineDatum`) | Inline only, `TxDats mempty` |
| **Our DSL** | `payTo'(addr, value, datum)` — typed, inline. `output` for raw | Inline only (MPFS scope). Extensible later. |

**Crucial insight:** MPFS only uses inline datums. Our DSL handles this via `ToData` existential in `payTo'`. Datum hash support can be added later if needed.

### Case 6: Coin Selection Algorithms

**The problem:** Choose UTxOs from a wallet to cover the transaction's required value (outputs + fee + min-UTxO for change).

**Approaches:**

| Library | Algorithms |
|---------|-----------|
| **CSL/CML** | LargestFirst, RandomImprove, LargestFirstMultiAsset, RandomImproveMultiAsset (CIP-2) |
| **PyCardano** | LargestFirst + RandomImproveMultiAsset (dual fallback) |
| **Atlas** | Adapted from cardano-wallet |
| **cardano-balance-tx** | From cardano-wallet (standalone) |
| **Lucid Evolution** | Delegated to CML |
| **Blaze** | Pluggable `useCoinSelector(selector)` |
| **CardanoSharp** | LargestFirst + RandomImprove with pluggable strategy |
| **Scalus** | In `complete()`, largest UTxOs first |
| **Pallas** | None (manual) |
| **cardano-go** | None (manual) |
| **Our DSL** | Delegated to existing `balanceTx` (largest-first ADA-only) |

**Crucial insight:** Coin selection is a solved problem (CIP-2). Our existing `balanceTx` handles it for the ADA-only case. Multi-asset coin selection is out of scope unless MPFS needs it.

### Case 7: Script Evaluation (ExUnits)

**The problem:** Plutus scripts need execution budgets (CPU + memory units) set in their redeemers. These are only known after running the scripts against the assembled transaction.

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | Built-in CEK machine (same as cardano-node) |
| **CML** | Two-phase: `build_for_evaluation()` → external eval → `set_exunits()` → `build()` |
| **CSL** | External evaluator |
| **Lucid Evolution** | Local UPLC evaluation via `@lucid-evolution/uplc` |
| **Blaze** | Pluggable `useEvaluator(evaluator)` |
| **PyCardano** | Auto via `ChainContext.evaluate_tx()` (delegates to node/Blockfrost) |
| **cardano-js-sdk** | Pluggable `TxEvaluator` interface |
| **MPFS** | Via Provider's `evaluateTx` (node socket) |
| **Our DSL** | Via evaluator function parameter to `build` |

**Crucial insight:** ExUnit evaluation is always external to the builder. The builder needs: (1) assemble with placeholders, (2) call evaluator, (3) patch results. Our `build` loop does this. CML's two-phase pattern is closest to our `draft` + `build` separation.

### Case 8: Composability (Multiple Protocols in One Tx)

**The problem:** Compose interactions with multiple independent protocols in a single transaction. Each protocol knows its own UTxO patterns but shouldn't know about the others.

**Approaches:**

| Library | Approach |
|---------|----------|
| **Scalus** | `UtxoCellDef.apply(action)` → `Deferred` step encapsulates query + resolver per protocol |
| **Blaze** | `preCompleteHooks` — multiple hooks can modify the tx independently |
| **Atlas** | `GYTxBuilderMonad` — monadic composition with `buildTxBodyParallel` for independent tx chains |
| **cardano-js-sdk** | `customize(cb)` — single callback, but composable via function composition |
| **Most others** | Manual — caller must orchestrate all protocol interactions |
| **Our DSL** | `Ctx :: q a -> TxInstr q a` — each protocol defines its query GADT, composed via sum type or extensible effects |

**Crucial insight:** Scalus's UtxoCell pattern is the gold standard for composable protocol interactions. Our `Ctx` instruction with pluggable `q` enables the same pattern. The operational monad's bind gives us natural sequencing that Scalus achieves through `Deferred` step resolution.

### Case 9: Pay vs Lock Semantic Safety

**The problem:** Paying to a script address without a datum is almost always a bug (funds locked forever). Some libraries enforce this at the API level.

**Approaches:**

| Library | Approach |
|---------|----------|
| **Blaze** | `payAssets` (asserts payment address) vs `lockAssets` (asserts script address + requires datum) |
| **Lucid Evolution** | `pay.ToAddress` vs `pay.ToContract` (soft distinction) |
| **Scalus** | No enforcement — `payTo(scriptAddress, value)` without datum is allowed |
| **PyCardano** | No enforcement |
| **CSL/CML** | No enforcement |
| **Our DSL** | No enforcement currently. Could add `lockAt` that requires `ToData d => d` |

**Crucial insight:** Blaze's approach is the cleanest. Worth considering for our DSL as a future addition, but not blocking — MPFS always uses `payTo'` with datums for script outputs.

### Case 10: Fee Estimation Method

**The problem:** Estimate the transaction fee before the final transaction is known (chicken-and-egg: fee affects size, size affects fee).

**Approaches:**

| Method | Used by |
|--------|---------|
| **Fake-witness serialization** | CSL, CML — build full tx with fake witnesses of correct size, serialize, compute fee from size |
| **Iterative convergence** | Scalus (20 iter), Blaze (10 iter), our DSL (20 iter) — loop until fee stabilizes |
| **Two-pass** | PyCardano, Lucid — estimate → build → precise fee |
| **estimateMinFeeTx** | cardano-ledger-api — single-pass with witness count |
| **Manual** | Pallas, CardanoSharp, cardano-go |
| **Our existing balanceTx** | Uses `estimateMinFeeTx` iteratively (max 10 rounds) |

**Crucial insight:** Our `balanceTx` already handles this. The `build` loop adds another layer of iteration for `WithFinalTx` convergence. Two nested loops — inner (fee convergence in `balanceTx`) and outer (`WithFinalTx` convergence in `build`).

---

## Full Feature Matrix (25 libraries)

| # | Library | Lang | Script | Mint | Datum | Redeemer | Fee | CoinSel | Balance | Deferred |
|---|---------|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | cardano-api | Haskell | Y | Y | Y | Y | Y | - | Y | experimental |
| 2 | Atlas | Haskell | Y | Y | Y | Y | Y | Y | Y | skeleton |
| 3 | cooked-validators | Haskell | Y | Y | Y | Y | Y | - | Y | skeleton |
| 4 | Convex/sc-tools | Haskell | Y | Y | Y | Y | Y | Y | Y | - |
| 5 | Scalus | Scala | Y | Y | Y | Y | Y | Y | Y | 3 mechanisms |
| 6 | cardano-client-lib | Java | Y | Y | Y | Y | Y | Y | Y | - |
| 7 | CSL | Rust/WASM | Y | Y | Y | Y | Y | Y | Y | - |
| 8 | CML | Rust/WASM | Y | Y | Y | Y | Y | Y | Y | 2-phase eval |
| 9 | Whisky | Rust/WASM | Y | Y | Y | Y | Y | Y | Y | - |
| 10 | Lucid Evolution | TS | Y | Y | Y | Y | Y | Y | Y | RedeemerBuilder |
| 11 | Blaze | TS | Y | Y | Y | Y | Y | Y | Y | preCompleteHooks |
| 12 | Mesh SDK | TS | Y | Y | Y | Y | Y | Y | Y | - |
| 13 | cardano-js-sdk | TS | Y | Y | Y | Y | Y | Y | Y | lazy build + customize |
| 14 | Buildooor | TS | Y | Y | Y | Y | Y | Y | Y | deferred resolve |
| 15 | CTL | PureScript | Y | Y | Y | Y | Y | Y | Y | constraints |
| 16 | PyCardano | Python | Y | Y | Y | Y | Y | Y | Y | auto-eval |
| 17 | CardanoSharp | C# | Y | Y | Y | Y | manual | Y | - | - |
| 18 | Pallas | Rust | Y | Y | Y | Y | manual | - | - | - |
| 19 | Rum | Go | Y | Y | Y | Y | - | - | - | - |
| 20 | cardano-go | Go | Y | Y | - | - | Y | - | basic | - |
| 21 | Helios tx-utils | JS | Y | Y | Y | Y | Y | Y | Y | - |
| 22 | TyphonJS | TS | Y | Y | Y | Y | Y | - | - | - |
| 23 | Kuber | Haskell | Y | Y | Y | Y | Y | Y | Y | - |
| 24 | hydra-cardano-api | Haskell | Y | Y | Y | Y | Y | - | Y | - |
| 25 | **Our DSL** | Haskell | Y | Y | Y | Y | Y | Y | Y | **3 unified** |

### Case 11: The Simulation Gap (Derived Application State)

**Problem:** Real applications maintain derived state (databases, indexes, caches) updated asynchronously by a chain follower. Simulators provide raw `LedgerState` / UTxO queries but don't update the application's derived state after each simulated transaction. Every builder that claims "test without a node" hits this: the context queries in simulation don't go through the same code path as production.

**Who is affected:** Every tx builder with simulation support — Scalus Emulator, cardano-node-emulator, PyCardano ChainContext, Blaze, Lucid. None document this gap.

**Scalus UtxoCell** hides it best: the cell's state IS the inline datum on the UTxO, so raw UTxO queries = application state queries. But this only works when all state lives on-chain as inline datums.

**MPFS example:** Production queries a CSMT-UTxO database (RocksDB, updated by chain follower). Simulation queries raw `LedgerState` UTxOs. The filtering logic must exist in both — or be factored out:

```
classifyTx :: Tx -> [StateUpdate]     -- pure, shared
applyUpdates :: Storage -> [StateUpdate] -> IO ()     -- production
applyUpdates :: SimState -> [StateUpdate] -> SimState  -- simulation
```

**What our DSL does:** Makes the gap explicit via `Ctx q`. Same `q` GADT, different interpreters. The simulation interpreter is knowingly a simplification. Testing the full chain-sync → derived-state → query → build → submit → sync cycle requires a devnet. The builder should not pretend simulation replaces integration testing.

## Summary: What Our DSL Uniquely Provides

| Capability | Closest prior art | Our advantage |
|-----------|------------------|---------------|
| Operational monad builder | None (all use fluent/mutable) | Bind for forward values, instructions as data |
| `WithFinalTx` fixpoint | Scalus `redeemerBuilder`, Lucid `RedeemerBuilder` | Fully general — any type, not just `Data` or indices |
| Pluggable context `q` | Scalus `Deferred(query, resolve)` | Type-safe queries with `GCompare`, `DMap` for tests |
| Position-returning instructions | None | `spend` returns `Word32`, resolved by fixpoint |
| Fee-dependent outputs | Scalus iterative loop, MPFS `balanceFeeLoop` | Natural via `withFinalTx` — no special callback API |
| Composable protocol interactions | Scalus UtxoCellDef | `Ctx` + query GADT sum types |
