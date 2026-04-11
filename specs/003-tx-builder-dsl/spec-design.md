# Transaction Builder DSL for cardano-node-clients

**Location:** new module(s) inside `cardano-node-clients`
**Inspired by:** [Scalus](https://scalus.org) TxBuilder
**Scope:** Cover the transaction shapes used in MPFS offchain — no more, no less

## Problem

Every MPFS transaction builder (`Boot`, `Update`, `End`, `Retract`, `Reject`, `Request`) follows the same pattern:

1. Start with `mkBasicTxBody`
2. Set inputs via `& inputsTxBodyL .~ Set.fromList [...]`
3. Set outputs via `& outputsTxBodyL .~ StrictSeq.fromList [...]`
4. Maybe set mint via `& mintTxBodyL .~ mintMA`
5. Set collateral via `& collateralInputsTxBodyL .~ ...`
6. Maybe set reference inputs, required signers, validity interval
7. Build redeemers map with manual `spendingIndex` computation and `placeholderExUnits`
8. Compute `scriptIntegrityHash` from pp + redeemers
9. Assemble `mkBasicTx body & witsTxL . scriptTxWitsL .~ ... & witsTxL . rdmrsTxWitsL .~ ...`
10. Call `evaluateAndBalance prov pp inputUtxos changeAddr tx`

Steps 7–10 are identical boilerplate across all 7 builders. Steps 1–6 are lens plumbing that obscures intent. The DSL should absorb the mechanical parts (index computation, integrity hash, ExUnits patching, redeemer assembly) while keeping the domain logic explicit.

## Transaction Shapes to Cover

Derived from MPFS offchain code:

| Tx type | Inputs | Ref inputs | Outputs | Mint | Redeemers | Validity | Req signers |
|---------|--------|------------|---------|------|-----------|----------|-------------|
| **Boot** | 1 seed UTxO | — | 1 state (script addr, token+datum) | +1 token (Minting redeemer) | 1 mint | — | — |
| **Request** (insert/delete/update) | wallet UTxOs | — | 1 request (script addr, datum) | — | — | — | — |
| **Update** | state + N requests + fee | — | 1 new state + N refunds | — | 1 spend (Modify) + N spend (Contribute) | upper bound | owner |
| **Retract** | request + fee | state (ref) | — | — | 1 spend (Retract) | lower + upper | request owner |
| **Reject** | state + N requests + fee | — | 1 new state + N refunds | — | 1 spend + N spend (Reject) | lower + upper | owner |
| **End** | state + fee | — | — | -1 token (Burning redeemer) | 1 spend (End) + 1 mint (Burning) | — | owner |
| **Simple transfer** | 1 UTxO | — | 1 recipient | — | — | — | — |

## DSL Design

Operational monad parameterized by pluggable context `q` and error type `e`. Three non-building instructions: `Peek` (fixpoint values from the Tx), `Valid` (ledger and custom checks), and `Ctx` (domain queries). Scalus's three deferred mechanisms collapse into `Peek` + `Ctx`; validation is a new axis no other library has as a composable instruction.

### Instruction GADT

```haskell
data TxInstr q e a where
    -- Transaction building (fixed, we define these)
    Spend        :: TxIn -> SpendWitness -> TxInstr q e ()
    Reference    :: TxIn -> TxInstr q e ()
    Collateral   :: TxIn -> TxInstr q e ()
    Send         :: TxOut ConwayEra -> TxInstr q e ()
    MintI        :: PolicyID -> AssetName -> Integer -> MintWitness -> TxInstr q e ()
    SetValidFrom :: SlotNo -> TxInstr q e ()
    SetValidTo   :: SlotNo -> TxInstr q e ()
    ReqSignature :: KeyHash 'Witness -> TxInstr q e ()
    AttachScript :: Script ConwayEra -> TxInstr q e ()
    -- Peek at the final Tx (fixpoint, produces values)
    Peek         :: (Tx ConwayEra -> Convergence a) -> TxInstr q e a
    -- Validate the final Tx (produces errors, not values)
    Valid        :: (Tx ConwayEra -> Check e) -> TxInstr q e ()
    -- Pluggable context: user-defined queries
    Ctx          :: q a -> TxInstr q e a

type TxBuild q e = Program (TxInstr q e)

-- Fixpoint convergence
data Convergence a = Iterate a | Ok a

-- Validation result
data Check e = Pass | LedgerFail LedgerCheck | CustomFail e

-- Library-provided ledger checks (closed)
data LedgerCheck
    = MinUtxoViolation Word32 Coin Coin
    | TxSizeExceeded Natural Natural
    | ValueNotConserved Value Value
    | CollateralInsufficient Coin Coin

data SpendWitness
    = PubKeyWitness
    | forall r. ToData r => ScriptWitness r

data MintWitness
    = forall r. ToData r => PlutusScriptWitness r

-- Interpreter newtypes (avoid impredicativity)
newtype Interpret q = Interpret { runInterpret :: forall x. q x -> x }
newtype InterpretIO q = InterpretIO { runInterpretIO :: forall x. q x -> IO x }
```

### Smart constructors

Position-dependent instructions use `Peek` internally. The user binds the result naturally.

```haskell
-- Inputs: return spending index (resolved by fixpoint)
spend        :: TxIn -> TxBuild q e Word32
spendScript  :: ToData r => TxIn -> r -> TxBuild q e Word32

-- Outputs: return output index (resolved by fixpoint)
payTo        :: Addr -> MaryValue -> TxBuild q e Word32
payTo'       :: ToData d => Addr -> MaryValue -> d -> TxBuild q e Word32
output       :: TxOut ConwayEra -> TxBuild q e Word32

-- These return ()
reference        :: TxIn -> TxBuild q e ()
collateral       :: TxIn -> TxBuild q e ()
mint             :: ToData r => PolicyID -> Map AssetName Integer -> r -> TxBuild q e ()
validFrom        :: SlotNo -> TxBuild q e ()
validTo          :: SlotNo -> TxBuild q e ()
requireSignature :: KeyHash 'Witness -> TxBuild q e ()
attachScript     :: Script ConwayEra -> TxBuild q e ()

-- Raw Peek (user controls convergence)
peek :: (Tx ConwayEra -> Convergence a) -> TxBuild q e a

-- Validation (user or library checks)
valid :: (Tx ConwayEra -> Check e) -> TxBuild q e ()

-- Pluggable context query
ctx :: q a -> TxBuild q e a
```

Library-provided checkers:

```haskell
checkMinUtxo     :: PParams -> Word32 -> TxBuild q e ()
checkTxSize      :: PParams -> TxBuild q e ()
checkConservation :: TxBuild q e ()
checkCollateral  :: PParams -> TxBuild q e ()
```

Each is a `valid` call that produces `LedgerFail` on failure. The user opts in by including them in their program — they're not mandatory.

### The three axes

**`Peek`** — extract a value from the final Tx (fixpoint). Replaces Scalus's `redeemerBuilder` and `datumBuilder`. Returns `Convergence a`: `Ok a` (done) or `Iterate a` (use this value, keep going). The build loop iterates until all `Peek`s return `Ok`.

**`Valid`** — check a property of the final Tx. Returns `Check e`: `Pass`, `LedgerFail LedgerCheck`, or `CustomFail e`. Runs after convergence. The interpreter collects all failures.

**`Ctx`** — query domain-specific context. Replaces Scalus's `Deferred(query, resolve)`. One-shot, not part of the fixpoint.

They compose freely:

```haskell
updateTx :: TxBuild CageQ CageErr ()
updateTx = do
    -- Ctx: domain query
    (stateIn, datum) <- ctx (FindState pid tid)
    reqs <- ctx (FindReqs tid)

    -- Pure computation
    let newRoot = computeRoot datum proofs

    -- Tx building (spend returns index via Peek)
    stateIdx <- spendScript stateIn (Modify proofs)
    forM_ reqs $ \(reqIn, _) ->
        spendScript reqIn (Contribute (txInToRef stateIn))

    -- Peek: fee-dependent refund (fixpoint)
    Coin feeVal <- peek $ \tx ->
        let fee = tx ^. bodyTxL . feeTxBodyL
        in if fee > Coin 0 then Ok fee else Iterate (Coin 0)
    let refund = totalIn - feeVal - numReqs * tip
    payTo' scriptAddr stateValue (StateDatum newRoot)
    forM_ (zip [0..] reqs) $ \(i, _) ->
        payTo ownerAddr (inject (Coin (perReq i refund)))

    -- Valid: opt-in checks
    outIdx <- payTo' scriptAddr stateValue newDatum
    checkMinUtxo pp outIdx

    -- Valid: custom domain check
    valid $ \tx -> if someInvariant tx then Pass
                   else CustomFail InvalidStateTransition

    collateral feeIn
    requireSignature ownerKh
    validTo upperSlot
    attachScript script
```

### Interpreters

```haskell
-- Pure: no context, no Peek iteration, no Valid
-- q = Void, e = Void
draft
    :: PParams ConwayEra
    -> TxBuild Void Void a
    -> Tx ConwayEra

-- Pure with precomputed context answers
draftWith
    :: PParams ConwayEra
    -> DMap q Identity
    -> TxBuild q e a
    -> Tx ConwayEra

-- Full: context + Peek fixpoint + evaluation + balancing + Valid checks
build
    :: PParams ConwayEra
    -> InterpretIO q          -- context interpreter
    -> (Tx ConwayEra -> IO EvalResult)   -- script evaluator
    -> [(TxIn, TxOut ConwayEra)]         -- input UTxOs
    -> Addr                              -- change address
    -> TxBuild q e a
    -> IO (Either (BuildError e) (Tx ConwayEra))

data BuildError e
    = EvalFailure ScriptHash String [Text]
    | BalanceFailed BalanceError
    | ChecksFailed [Check e]   -- all failed Valid checks
```

Interpreter loop:
1. Resolve `Ctx` queries (one-shot, via natural transformation)
2. Interpret `Peek` nodes with current Tx → collect `Ok`/`Iterate`
3. Assemble Tx from steps
4. Evaluate scripts → ExUnits → patch → recompute integrity hash
5. Balance (inner fee loop)
6. If any `Peek` returned `Iterate` → goto 2 with new Tx
7. All `Peek` returned `Ok` AND Tx stable → run `Valid` checks
8. If any `Check` ≠ `Pass` → return `Left (ChecksFailed failures)`
9. All pass → return `Right tx`

### Example: MPFS queries and errors

```haskell
-- Queries (pluggable context)
data CageQ a where
    FindState :: PolicyID -> TokenId -> CageQ (TxIn, CageDatum)
    FindReqs  :: TokenId -> CageQ [(TxIn, CageDatum)]
    GetParams :: CageQ (PParams ConwayEra)

-- Errors (custom failures)
data CageErr
    = InvalidStateTransition
    | InsufficientTip Coin
    | InvalidRoot ByteString

-- Production interpreter
cageInterpreter :: Provider IO -> CageQ a -> IO a
cageInterpreter prov (FindState pid tid) = ...
cageInterpreter prov (FindReqs tid) = ...
cageInterpreter prov GetParams = queryProtocolParams prov

-- Test interpreter
testAnswers :: DMap CageQ Identity
testAnswers = DMap.fromList
    [ FindState pid tid :=> Identity (mockIn, mockDatum)
    , FindReqs tid :=> Identity [(req1, d1), (req2, d2)]
    , GetParams :=> Identity emptyPParams
    ]
```

## What MPFS builders become

### Boot

**Before** (~120 lines): manual redeemer map, integrity hash, lens plumbing, evaluateAndBalance.

**After** (~20 lines):
```haskell
bootTx :: TxBuild CageQ CageErr ()
bootTx = do
    pp <- ctx GetParams
    (seedIn, _) <- ctx (FindFeeUtxo addr)
    let onChainRef = txInToRef seedIn
        assetName = deriveAssetName onChainRef
    spend seedIn
    payTo' scriptAddr (MaryValue 2_000_000 mintMA) stateDatum
    mint policyId (Map.singleton assetName 1) (Minting (Mint onChainRef))
    collateral seedIn
    attachScript script
```

### End

**Before** (~100 lines): dual redeemers (spend + mint), manual index computation.

**After** (~15 lines):
```haskell
endTx :: TxBuild CageQ CageErr ()
endTx = do
    (stateIn, datum) <- ctx (FindState pid tid)
    (feeIn, _) <- ctx (FindFeeUtxo addr)
    let ownerKh = extractOwner datum
    spendScript stateIn End
    mint policyId (Map.singleton assetName (-1)) Burning
    collateral feeIn
    requireSignature ownerKh
    attachScript script
```

### Modify/Reject (conservation-aware, fee-dependent outputs)

**Before** (~250 lines in `buildConservationTx`): manual `balanceFeeLoop` with `mkOutputs` callback, two-phase evaluation, manual ExUnits patching, manual index computation.

**After** (~30 lines):
```haskell
modifyTx :: TxBuild CageQ CageErr ()
modifyTx = do
    (stateIn, datum) <- ctx (FindState pid tid)
    reqs <- ctx (FindReqs tid)
    (feeIn, _) <- ctx (FindFeeUtxo addr)
    let stateRef = txInToRef stateIn
        proofs = computeProofs datum reqs
        numReqs = length reqs
        totalIn = sum [c | (_, out) <- reqs, let Coin c = out ^. coinTxOutL]
    spendScript stateIn (Modify proofs)
    forM_ reqs $ \(reqIn, _) ->
        spendScript reqIn (Contribute stateRef)
    -- Refunds depend on the final fee (fixpoint)
    Coin feeVal <- peek $ \tx ->
        tx ^. bodyTxL . feeTxBodyL
    let totalRefund = totalIn - feeVal - numReqs * tip
        perRequest = totalRefund `div` numReqs
        remainder = totalRefund `mod` numReqs
    payTo' scriptAddr (MaryValue (Coin (2_000_000 + numReqs * tip)) mint) newDatum
    forM_ (zip [0..] reqs) $ \(i, _) ->
        payTo ownerAddr (inject (Coin (perRequest + if i == 0 then remainder else 0)))
    collateral (fst feeUtxo)
    requireSignature (extractOwner datum)
    validTo upperSlot
    attachScript script
```

The `balanceFeeLoop` with its `mkOutputs` callback disappears entirely. `peek` reads the fee from the fixpoint, and the build loop converges naturally (2–3 iterations). This is the exact use case from [cardano-foundation/cardano-mpfs-onchain#37](https://github.com/cardano-foundation/cardano-mpfs-onchain/pull/37).

### Retract (reference input + validity window)

**Before** (~150 lines): reference input, validity computation, manual redeemer with state ref.

**After** (~20 lines):
```haskell
retractTx :: TxBuild CageQ CageErr ()
retractTx = do
    (stateIn, stateDatum) <- ctx (FindState pid tid)
    (reqIn, reqDatum) <- ctx (FindRequest reqTxIn)
    (feeIn, _) <- ctx (FindFeeUtxo addr)
    let ownerKh = extractRequestOwner reqDatum
        stateRef = txInToRef stateIn
    reference stateIn          -- not consumed
    spendScript reqIn (Retract stateRef)
    collateral feeIn
    requireSignature ownerKh
    validFrom lowerSlot
    validTo upperSlot
    attachScript script
```

### Simple transfer (no scripts)

```haskell
transferTx :: TxBuild Void ()
transferTx = do
    spend seedIn
    payTo recipientAddr (inject (Coin 5_000_000))
```

Note: `q = Void` — no context needed, works with pure `draft`.

### Composing two protocols in one transaction

```haskell
-- Two independent protocol interactions
composedTx :: TxBuild AppQ ()
composedTx = do
    -- Protocol A: spend a cage state
    (stateIn, datum) <- ctx (CageQuery (FindState pid tid))
    spendScript stateIn (Modify proofs)
    payTo' scriptAddr stateValue newDatum

    -- Protocol B: mint an NFT
    (seedIn, _) <- ctx (NftQuery (FindSeed addr))
    let nftName = deriveNftName seedIn
    spend seedIn
    mint nftPolicyId (Map.singleton nftName 1) NftMint
    payTo' nftAddr (MaryValue 2_000_000 nftMA) nftDatum

    -- Shared concerns
    (feeIn, _) <- ctx (WalletQuery (FindFeeUtxo addr))
    collateral feeIn
    attachScript cageScript
    attachScript nftScript
```

Each protocol defines its own query constructors in a sum type `AppQ`. The interpreter handles all of them. Neither protocol knows about the other.

## Crucial cases from ecosystem survey

The [survey](/code/cardano-tx-builder-survey.md) identified 10 crucial cases across 25 libraries. Coverage:

| Case | Covered | How |
|------|---------|-----|
| 1. Redeemer index computation | Yes | Auto in interpreter, returned via `Peek` |
| 2. Fee-dependent outputs | Yes | `peek` reads fee, Modify example |
| 3. Deferred redeemers | Yes | `Peek` (general, any type) |
| 4. Deferred UTxO queries | Yes | `Ctx q a` (pluggable, typed) |
| 5. Datum handling (inline) | Yes | `payTo'` with `ToData d` |
| 5b. Datum handling (hash) | Deferred | Not needed for MPFS; add `payToHash` later |
| 6. Coin selection | Delegated | Existing `balanceTx` (ADA-only largest-first) |
| 7. Script evaluation | Yes | Evaluator function parameter to `build` |
| 8. Composability | Yes | `Ctx` with sum-type queries, example above |
| 9. Pay vs Lock safety | Deferred | Could add `lockAt` that requires datum; not blocking |
| 10. Fee estimation | Yes | Two nested loops: inner (balanceTx), outer (`Peek`) |
| 11. Tx validation | **New** | `Valid` with `Check e` — opt-in composable checkers |

## What stays in MPFS

Domain logic only — no transaction mechanics:

- Query GADT definition (`CageQ`)
- Query interpreter (production: node queries, test: DMap fixtures)
- Datum types and construction
- Proof generation (trie operations)
- Validity interval computation (phase boundaries)
- Business rules (fee calculation, refund amounts)

## Integration with existing code

- **`Balance.hs`** — unchanged, `build` calls it internally
- **`Provider`** — used inside the `CageQ` interpreter, not by the DSL
- **`evaluateAndBalance`** — absorbed into `build`, deprecated
- **`spendingIndex`** — absorbed into interpreter, deprecated
- **`computeScriptIntegrity`** — absorbed into interpreter, deprecated
- **`placeholderExUnits`** — absorbed into interpreter, deprecated

## Implementation plan

Vertical slices — each delivers one working end-to-end feature with types, logic, interpreter support, and tests in one commit.

### Slice 1: Simple pub-key spend + draft
- `TxInstr q e a` GADT with `Spend`, `Send`, `Collateral`
- `Convergence`, `Check`, `LedgerCheck`, `Interpret`, `InterpretIO` types
- `spend` (returns `Word32` via `Peek`), `payTo`, `collateral`
- `draft` interpreter (pure, `q = Void, e = Void`)
- Test: build a simple transfer, verify inputs/outputs in assembled Tx

### Slice 2: Script spend + mint + redeemer indices
- Add `MintI`, `AttachScript`, `ReqSignature` to GADT
- `spendScript`, `mint`, `attachScript`, `requireSignature`
- `draft` handles redeemer index computation (spending + minting)
- Test: Boot-shaped tx (spend + mint), End-shaped tx (spend + mint + burn), verify redeemer indices

### Slice 3: Peek convergence + build loop
- Add `Peek` instruction to GADT
- `build` interpreter with fixpoint iteration + evaluator + balancing
- `peek` smart constructor
- Test: fee-dependent outputs (conservation case from onchain#37)

### Slice 4: Ctx + pluggable queries
- Add `Ctx` instruction to GADT
- `Interpret`/`InterpretIO` wiring in `build`
- `ctx` smart constructor
- Test: define a test query GADT, use `ctx` in a builder, interpret with `Interpret`

### Slice 5: Valid + library checkers
- Add `Valid` instruction to GADT
- `valid` smart constructor, `checkMinUtxo`, `checkTxSize`
- Interpreter runs checks after `Peek` convergence
- Test: output below min UTxO → `LedgerFail`, custom check → `CustomFail`

### Slice 6: Reference inputs + validity intervals
- Add `Reference`, `SetValidFrom`, `SetValidTo`
- `reference`, `validFrom`, `validTo`
- Test: Retract-shaped tx (reference input + validity window + required signer)

### Phase 4: Transaction Logic Tester (separate ticket)

Not an emulator — a transaction logic tester. It validates that a sequence of `TxBuild` programs produces valid transactions against `cardano-ledger`'s `applyTx`. It does NOT replicate the production infrastructure (chain sync, RocksDB, concurrent queries, rollbacks).

#### Core: `applyTx` is pure

```haskell
applyTx :: Globals -> LedgerEnv era -> LedgerState era -> Tx era
        -> Either (ApplyTxError era) (LedgerState era, Validated (Tx era))
```

Pure function, real ledger rules, real `PredicateFailure` errors. No node needed.

#### Application state as a `Fold`

The tester needs a `Ctx` interpreter that tracks application state across transactions. The state evolves with each submitted tx. We model this as a `Fold` (from the `foldl` package):

```haskell
data Fold a b = forall s. Fold
    (s -> a -> s)  -- step
    s              -- initial
    (s -> b)       -- extract
```

The tester's fold consumes transactions and produces a `Ctx` interpreter:

```haskell
data Tester q = forall s. Tester
    { tLedgerState :: LedgerState ConwayEra
    , tGlobals     :: Globals
    , tEnv         :: LedgerEnv ConwayEra
    , tFold        :: Fold (Tx ConwayEra) (Interpret q)
    }
```

The `s` is existential — hidden inside the `Fold`. The user provides step + initial + extract. The tester feeds transactions and extracts the `Ctx` interpreter when needed.

#### Library-provided folds

We ship standard folds for common UTxO tracking:

```haskell
-- Track all live UTxOs (created - consumed)
utxoFold :: Fold (Tx ConwayEra) (Map TxIn (TxOut ConwayEra))

-- Track UTxOs at a specific address
utxoAtFold :: Addr -> Fold (Tx ConwayEra) (Map TxIn (TxOut ConwayEra))

-- Track UTxOs holding a specific policy
utxoByPolicyFold :: PolicyID -> Fold (Tx ConwayEra) (Map TxIn (TxOut ConwayEra))
```

The user composes them with domain-specific folds via `Applicative`:

```haskell
cageFold :: PolicyID -> Addr -> Fold (Tx ConwayEra) (forall x. CageQ x -> x)
cageFold pid scriptAddr = mkCageCtx
    <$> utxoByPolicyFold pid   -- state UTxOs (library)
    <*> utxoAtFold scriptAddr  -- all cage UTxOs (library)
    <*> trieFold               -- trie state (user's domain logic)
```

#### API

```haskell
initTester
    :: Globals -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]       -- genesis funds
    -> Fold (Tx ConwayEra) (Interpret q)
    -> Tester q

submitTx :: Tx ConwayEra -> Tester q
         -> Either (ApplyTxError ConwayEra) (Tester q)

ctxInterpreter :: Tester q -> Interpret q

advanceSlot :: SlotNo -> Tester q -> Tester q
```

#### What it tests, what it doesn't

**Tests:**
- Transaction validity (same `applyTx` as the node)
- Builder logic (redeemer indices, integrity hash, balancing)
- Multi-step protocol flows (state machine transitions)
- `Peek` convergence (fee-dependent outputs)
- `Valid` checks (opt-in pre-flight validation)

**Does NOT test:**
- Chain sync / chain follower infrastructure
- Database read/write path (RocksDB, CSMT-UTxO)
- Concurrent query/submit races
- Rollbacks / chain switches
- Block-level semantics (tx ordering within blocks)

The fold the user provides is *morally equivalent* to their production chain follower — same logic, different infrastructure. It's a specification of the fold, not a port of the production code. The gap (Case 11) is inherent and explicit.

## Decided

1. **`TxInstr q e a` — two user type parameters.** `q` for pluggable context queries, `e` for custom validation errors. The DSL handles tx building; `q` and `e` are the user's domain.

2. **Three non-building instructions.** `Peek` for fixpoint values from the Tx. `Valid` for opt-in validation checks. `Ctx` for domain queries. Replaces Scalus's three deferred mechanisms and adds validation as a composable instruction.

3. **`Peek` with `Convergence`.** `data Convergence a = Iterate a | Ok a`. The function controls convergence — returns `Iterate` with a best-effort value or `Ok` when satisfied. No artificial iteration cap. Non-convergence is the user's bug.

4. **`Valid` with `Check e`.** `data Check e = Pass | LedgerFail LedgerCheck | CustomFail e`. `LedgerCheck` is closed (library-provided: min UTxO, tx size, conservation, collateral). `e` is open (user-provided). Checks run after `Peek` convergence.

5. **Library checkers are opt-in.** `checkMinUtxo`, `checkTxSize`, `checkConservation`, `checkCollateral` are smart constructors the user includes in their program. Not mandatory, not baked into the interpreter.

6. **Position-returning instructions.** `spend` returns `Word32` (input index), `payTo` returns `Word32` (output index). Resolved via `Peek` internally — one mechanism, no special cases.

7. **Interpreter-polymorphic.** `draft` is pure (`q = Void, e = Void`). `draftWith` uses `DMap q Identity`. `build` uses `InterpretIO q`. Same program, different semantics.

8. **Existential redeemers and datums.** `SpendWitness` and `MintWitness` use existentials with `ToData` constraint. Type-safe at construction, erased at assembly.

9. **Lives in `cardano-node-clients`.** Module `Cardano.Node.Client.TxBuild`.

10. **Two nested loops in `build`.** Inner: `balanceTx` iterates fee estimation. Outer: `Peek` fixpoint re-interprets the program. Convergence: inner is fee-monotonic; outer is user-controlled via `Convergence`.

11. **Valid runs after convergence.** The interpreter first converges all `Peek` nodes, then runs all `Valid` checks on the final Tx. Checks see the fully balanced, converged transaction.

12. **Transaction logic tester, not emulator.** Phase 4 provides `applyTx`-based validation, not a production replica. Application state is a `Fold (Tx ConwayEra) (Interpret q)` — existential state, `Applicative` composition, library UTxO folds + user domain folds. The fold is morally equivalent to the production chain follower but doesn't share code with it. The simulation gap (Case 11) is inherent and explicit.

## Open Questions

1. **`GCompare` for `q`.** `DMap` lookup requires `GCompare q`. Is this acceptable, or should `draftWith` use `Interpret q` instead?

2. **Multi-asset coin selection.** Current `balanceTx` is ADA-only. Pluggable balancer (function record) can swap in `cardano-balance-tx` later.

3. **Epoch boundaries in emulator.** Do we need epoch transitions, reward calculations, stake snapshots? For MPFS testing probably not — slot advancement + UTxO management suffices.
