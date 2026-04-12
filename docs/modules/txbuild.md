# TxBuild

::: {.module}
`Cardano.Node.Client.TxBuild`
:::

Operational transaction builder DSL for Conway-era transactions.

## What exists today

The current implementation covers the first six slices of the DSL:

- spend, script spend, collateral, output, mint, signer, and script
  attachment instructions
- `Peek` for fixpoint-dependent values such as spend indices, output
  indices, and fee-driven outputs
- `Ctx` for pluggable domain queries
- `Valid` for post-convergence transaction checks
- reference inputs and validity interval instructions
- pure interpreters with `draft` and `draftWith`
- effectful building with `build`, including script evaluation,
  `ExUnits` patching, eval retry, oscillation handling, bisection,
  and balancing

## Core types

```haskell
type TxBuild q e = Program (TxInstr q e)

data Convergence a
    = Iterate a
    | Ok a

newtype Interpret q = Interpret
    { runInterpret :: forall x. q x -> x
    }

newtype InterpretIO q = InterpretIO
    { runInterpretIO :: forall x. q x -> IO x
    }
```

`q` is the query GADT used by `Ctx`. `e` is reserved for custom
validation errors carried by `Valid`.

## Main entry points

```haskell
draft
    :: PParams ConwayEra
    -> TxBuild q e a
    -> Tx ConwayEra

draftWith
    :: PParams ConwayEra
    -> Interpret q
    -> TxBuild q e a
    -> Tx ConwayEra

build
    :: PParams ConwayEra
    -> InterpretIO q
    -> (Tx ConwayEra -> IO (Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)))
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> TxBuild q e a
    -> IO (Either (BuildError e) (Tx ConwayEra))
```

Use `draft` when the program has no `Ctx`. Use `draftWith` when it
does. Use `build` when the transaction needs full script evaluation and
balancing.

## Smart constructors

```haskell
spend            :: TxIn -> TxBuild q e Word32
spendScript      :: ToData r => TxIn -> r -> TxBuild q e Word32
collateral       :: TxIn -> TxBuild q e ()
payTo            :: Addr -> MaryValue -> TxBuild q e Word32
payTo'           :: ToData d => Addr -> MaryValue -> d -> TxBuild q e Word32
output           :: TxOut ConwayEra -> TxBuild q e Word32
mint             :: ToData r => PolicyID -> Map AssetName Integer -> r -> TxBuild q e ()
requireSignature :: KeyHash 'Witness -> TxBuild q e ()
attachScript     :: Script ConwayEra -> TxBuild q e ()
reference        :: TxIn -> TxBuild q e ()
validFrom        :: SlotNo -> TxBuild q e ()
validTo          :: SlotNo -> TxBuild q e ()
peek             :: (Tx ConwayEra -> Convergence a) -> TxBuild q e a
ctx              :: q a -> TxBuild q e a
valid            :: (Tx ConwayEra -> Check e) -> TxBuild q e ()
checkMinUtxo     :: PParams ConwayEra -> Word32 -> TxBuild q e ()
checkTxSize      :: PParams ConwayEra -> TxBuild q e ()
```

Position-dependent combinators such as `spend` and `payTo` use `Peek`
internally so the caller gets the final index after assembly.

## Example

### Pure draft

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Cardano.Ledger.BaseTypes (Inject (inject))
import Cardano.Ledger.Coin (Coin (..))

simpleTransfer :: TxBuild q e ()
simpleTransfer = do
    _ <- spend walletInput
    collateral collateralInput
    _ <- payTo recipientAddr (inject (Coin 7_000_000))
    pure ()

tx :: Tx ConwayEra
tx = draft emptyPParams simpleTransfer
```

This is the smallest useful shape: spend a wallet input, add
collateral, and assemble a pure draft transaction.

### Context-aware draft

```haskell
{-# LANGUAGE GADTs #-}

data TestQ a where
    GetLovelace :: TestQ Integer

example :: TxBuild TestQ e ()
example = do
    amount <- ctx GetLovelace
    _ <- payTo someAddr (inject (Coin amount))
    pure ()

tx :: Tx ConwayEra
tx =
    draftWith emptyPParams
        (Interpret (\GetLovelace -> 7_000_000))
        example
```

Use `draftWith` when the builder depends on domain queries but still
needs a pure interpreter for testing.

### Build with `Peek` and `Valid`

```haskell
{-# LANGUAGE GADTs #-}

data WalletQ a where
    GetProtocolParams :: WalletQ (PParams ConwayEra)

checkedTx :: TxBuild WalletQ String ()
checkedTx = do
    pp <- ctx GetProtocolParams
    outIx <- payTo recipientAddr (inject (Coin 2_000_000))
    checkMinUtxo pp outIx
    checkTxSize pp
    fee <- peek $ \tx ->
        Ok (tx ^. bodyTxL . feeTxBodyL)
    valid $ \_tx ->
        if fee >= Coin 0
            then Pass
            else CustomFail "negative fee"
```

`Peek` is for values that only exist after assembly or balancing, such
as spending indices, output indices, and the final fee. `Valid` runs
after convergence, so checks see the final balanced transaction.

### Effectful build

```haskell
txOrErr <-
    build
        pp
        (InterpretIO runWalletQuery)
        evaluateTx
        inputUtxos
        changeAddr
        checkedTx
```

The same program can move from pure tests to production by swapping the
interpreter and calling `build` instead of `draftWith`.

### Reference input and validity window

```haskell
windowedTx :: TxBuild q e ()
windowedTx = do
    reference oracleRef
    validFrom lowerBound
    validTo upperBound
    requireSignature ownerWkh
    pure ()
```

This covers the common "read but do not spend" pattern for reference
inputs together with explicit validity bounds and signer requirements.

## Testing status

`TxBuildSpec` currently covers:

- spend and pay-to assembly
- collateral handling
- spend index ordering
- script-spend redeemers
- mint and burn redeemers
- `Peek` through `build`
- `Ctx` through both `draftWith` and `build`
- `Valid` custom failures
- `checkMinUtxo` failures
- `checkTxSize` failures
- all-pass validation
- reference-input and validity-interval assembly
- eval retry after script-evaluation failure
- fee oscillation with output re-interpretation
- `bumpFee` in isolation

`TxBuild` E2E coverage currently covers:

- submitted devnet transactions built with `build`
- `spend`, `payTo`, and `payTo'`
- `Ctx`, `Peek`, and `Valid`
- required signers and explicit validity intervals

Script-specific builder features such as `spendScript`, `mint`,
`attachScript`, and the real reference/collateral script paths are
still primarily covered by unit tests and downstream integration tests.
