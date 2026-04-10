{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.TxBuild
Description : Operational monad transaction builder DSL
License     : Apache-2.0

Monadic transaction builder for Conway-era Cardano
transactions. Instructions are a GADT interpreted
by 'draft' and 'build'. Three non-building
instructions: 'Peek' (fixpoint values from the
assembled Tx), 'Valid' (opt-in validation checks),
and 'Ctx' (pluggable domain queries).

Parameterized by @q@ (query GADT for domain
context) and @e@ (custom validation error type).
-}
module Cardano.Node.Client.TxBuild (
    -- * Monad
    TxBuild,
    TxInstr (..),

    -- * Convergence
    Convergence (..),

    -- * Interpreters
    Interpret (..),
    InterpretIO (..),

    -- * Witnesses
    SpendWitness (..),

    -- * Input combinators
    spend,
    collateral,

    -- * Output combinators
    payTo,
    output,

    -- * Deferred
    peek,

    -- * Assembly
    draft,

    -- * Internal (for testing)
    interpretWith,
    assembleTx,
) where

import Control.Monad.Operational (
    Program,
    ProgramViewT (Return, (:>>=)),
    singleton,
    view,
 )
import Data.List (elemIndex)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word32)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (
    Tx,
    bodyTxL,
    mkBasicTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import Lens.Micro ((&), (.~), (^.))

-- ----------------------------------------------------
-- Core types
-- ----------------------------------------------------

-- | Fixpoint convergence signal.
data Convergence a
    = {- | Not converged yet; use this value and
      keep iterating.
      -}
      Iterate a
    | -- | Converged; use this value and stop.
      Ok a
    deriving (Show, Eq, Functor)

-- | How a spent input is witnessed.
data SpendWitness
    = -- | Pub-key input, no redeemer needed.
      PubKeyWitness

-- | Pure query interpreter.
newtype Interpret q = Interpret
    { runInterpret :: forall x. q x -> x
    }

-- | Effectful query interpreter.
newtype InterpretIO q = InterpretIO
    { runInterpretIO :: forall x. q x -> IO x
    }

-- ----------------------------------------------------
-- Instruction GADT
-- ----------------------------------------------------

-- | Transaction building instructions.
data TxInstr q e a where
    -- | Spend an input with a witness.
    Spend ::
        TxIn -> SpendWitness -> TxInstr q e ()
    -- | Add a collateral input.
    Collateral :: TxIn -> TxInstr q e ()
    -- | Add an output.
    Send ::
        TxOut ConwayEra -> TxInstr q e ()
    -- | Peek at the final Tx (fixpoint).
    Peek ::
        (Tx ConwayEra -> Convergence a) ->
        TxInstr q e a

-- | Monadic transaction builder.
type TxBuild q e = Program (TxInstr q e)

-- ----------------------------------------------------
-- Smart constructors
-- ----------------------------------------------------

{- | Spend a pub-key UTxO. Returns the spending
index in the final sorted input set (resolved
via 'Peek').
-}
spend :: TxIn -> TxBuild q e Word32
spend txIn = do
    singleton $ Spend txIn PubKeyWitness
    singleton $ Peek $ \tx ->
        let ins = tx ^. bodyTxL . inputsTxBodyL
         in if Set.member txIn ins
                then Ok (spendingIndex txIn ins)
                else Iterate 0

-- | Add a collateral input.
collateral :: TxIn -> TxBuild q e ()
collateral txIn = singleton $ Collateral txIn

{- | Pay value to an address. Returns the output
index in the final output list (resolved via
'Peek').
-}
payTo ::
    Addr -> MaryValue -> TxBuild q e Word32
payTo addr val = do
    singleton $ Send $ mkBasicTxOut addr val
    singleton $ Peek $ \tx ->
        let outs = tx ^. bodyTxL . outputsTxBodyL
            target = mkBasicTxOut addr val
         in case elemIndex target (toList outs) of
                Just i -> Ok (fromIntegral i)
                Nothing -> Iterate 0
  where
    toList = foldr (:) []

-- | Add a raw output. Returns the output index.
output ::
    TxOut ConwayEra -> TxBuild q e Word32
output txOut = do
    singleton $ Send txOut
    singleton $ Peek $ \tx ->
        let outs = tx ^. bodyTxL . outputsTxBodyL
         in case elemIndex txOut (toList outs) of
                Just i -> Ok (fromIntegral i)
                Nothing -> Iterate 0
  where
    toList = foldr (:) []

-- | Peek at the final assembled Tx.
peek ::
    (Tx ConwayEra -> Convergence a) ->
    TxBuild q e a
peek = singleton . Peek

-- ----------------------------------------------------
-- Interpreter state
-- ----------------------------------------------------

-- | Accumulated state from interpreting 'TxBuild'.
data TxState = TxState
    { tsSpends :: [(TxIn, SpendWitness)]
    , tsCollIns :: [TxIn]
    , tsOuts :: [TxOut ConwayEra]
    }

emptyState :: TxState
emptyState =
    TxState
        { tsSpends = []
        , tsCollIns = []
        , tsOuts = []
        }

{- | Interpret a 'TxBuild' program into 'TxState'.
The 'Tx' argument resolves 'Peek' nodes.
-}
interpretWith ::
    Tx ConwayEra ->
    TxBuild q e a ->
    -- | (state, result, all converged?)
    (TxState, a, Bool)
interpretWith currentTx = go emptyState True
  where
    go ::
        TxState ->
        Bool ->
        TxBuild q' e' b ->
        (TxState, b, Bool)
    go st conv prog = case view prog of
        Return a -> (st, a, conv)
        Spend txIn w :>>= k ->
            go
                st
                    { tsSpends =
                        tsSpends st ++ [(txIn, w)]
                    }
                conv
                (k ())
        Collateral txIn :>>= k ->
            go
                st
                    { tsCollIns =
                        tsCollIns st ++ [txIn]
                    }
                conv
                (k ())
        Send txOut :>>= k ->
            go
                st
                    { tsOuts =
                        tsOuts st ++ [txOut]
                    }
                conv
                (k ())
        Peek f :>>= k ->
            case f currentTx of
                Ok a -> go st conv (k a)
                Iterate a ->
                    go st False (k a)

-- | Assemble a 'Tx' from interpreter state.
assembleTx :: TxState -> Tx ConwayEra
assembleTx st =
    let
        allSpendIns =
            Set.fromList $ map fst (tsSpends st)
        collIns = Set.fromList (tsCollIns st)
        outs = StrictSeq.fromList (tsOuts st)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ allSpendIns
                & outputsTxBodyL .~ outs
                & collateralInputsTxBodyL .~ collIns
     in
        mkBasicTx body

-- ----------------------------------------------------
-- Assembly
-- ----------------------------------------------------

{- | Assemble a 'TxBuild' program into a 'Tx'
without evaluation or balancing.

Runs one pass: interprets with the initial (empty)
Tx, then assembles from collected steps. 'Peek'
nodes see the draft Tx on a second internal pass.
-}
draft ::
    PParams ConwayEra ->
    TxBuild q e a ->
    Tx ConwayEra
draft _pp prog =
    let
        -- Pass 1: collect steps with bogus Tx
        initialTx = mkBasicTx mkBasicTxBody
        (st1, _, _) = interpretWith initialTx prog
        -- Assemble from pass 1
        tx1 = assembleTx st1
        -- Pass 2: re-interpret with real Tx for
        -- Peek resolution
        (st2, _, _) = interpretWith tx1 prog
     in
        assembleTx st2

-- ----------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------

{- | Compute the spending index of a 'TxIn' in the
sorted input set.
-}
spendingIndex :: TxIn -> Set TxIn -> Word32
spendingIndex needle inputs =
    go 0 (Set.toAscList inputs)
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs
