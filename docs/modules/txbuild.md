# TxBuild

::: {.module}
`Cardano.Node.Client.TxBuild`
:::

Operational transaction builder DSL for Conway-era transactions.

## What exists today

The current implementation covers the first four slices of the DSL:

- spend, script spend, collateral, output, mint, signer, and script
  attachment instructions
- `Peek` for fixpoint-dependent values such as spend indices, output
  indices, and fee-driven outputs
- `Ctx` for pluggable domain queries
- pure interpreters with `draft` and `draftWith`
- effectful building with `build`, including script evaluation,
  `ExUnits` patching, and balancing

The next planned slices add `Valid`, reference inputs, and validity
interval support. Those APIs are described in the spec, but they are
not implemented in the module yet.

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
validation errors in later slices.

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
peek             :: (Tx ConwayEra -> Convergence a) -> TxBuild q e a
ctx              :: q a -> TxBuild q e a
```

Position-dependent combinators such as `spend` and `payTo` use `Peek`
internally so the caller gets the final index after assembly.

## Example

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

The same `TestQ` program can run through `build` by supplying an
`InterpretIO TestQ`.

## Testing status

`TxBuildSpec` currently covers:

- spend and pay-to assembly
- collateral handling
- spend index ordering
- script-spend redeemers
- mint and burn redeemers
- `Peek` through `build`
- `Ctx` through both `draftWith` and `build`
