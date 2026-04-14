{- |
Module      : Cardano.Node.Client.Evaluate
Description : Evaluate scripts and balance in one step
License     : Apache-2.0

Combines script evaluation, execution unit patching,
integrity hash recomputation, and transaction
balancing into a single function.

This is the standard workflow for submitting
transactions with Plutus scripts:

1. Build a tx with 'placeholderExUnits'
2. Call 'evaluateAndBalance'
3. Sign and submit

@
tx <- evaluateAndBalance PlutusV3 prov pp
        [feeUtxo, scriptUtxo] changeAddr unbalancedTx
let signed = addKeyWitness sk tx
submitTx submitter signed
@
-}
module Cardano.Node.Client.Evaluate (
    evaluateAndBalance,
) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Tx (
    Tx,
    bodyTxL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Plutus.Language (Language)
import Cardano.Ledger.TxIn (TxIn)

import Cardano.Node.Client.Balance (
    BalanceResult (..),
    balanceTx,
    computeScriptIntegrity,
 )
import Cardano.Node.Client.Provider (Provider (..))

{- | Evaluate Plutus scripts, patch execution units,
recompute the script integrity hash, and balance the
transaction.

The workflow:

1. Merge all input 'TxIn's into the body so the
   evaluator sees the complete input set (spending
   indices must match the redeemers).
2. Call 'evaluateTx' via the 'Provider' to get
   actual 'ExUnits' for each redeemer.
3. Patch each redeemer's 'ExUnits' from the
   evaluation result.
4. Recompute 'scriptIntegrityHash' with the patched
   redeemers.
5. Call 'balanceTx' to add fee inputs and a change
   output.

Throws an error if script evaluation fails or
balancing fails (insufficient funds).
-}
evaluateAndBalance ::
    Language ->
    Provider IO ->
    PParams ConwayEra ->
    {- | All input UTxOs (fee-paying and script).
    Their 'TxIn's are unioned with the body's
    inputs.
    -}
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    -- | Unbalanced tx with 'placeholderExUnits'
    Tx ConwayEra ->
    IO (Tx ConwayEra)
evaluateAndBalance lang prov pp inputUtxos changeAddr tx =
    do
        -- Pre-add all inputs so the evaluator sees
        -- the complete input set and spending indices
        -- match the redeemers.
        let existingIns =
                tx ^. bodyTxL . inputsTxBodyL
            allIns =
                foldl
                    ( \s (tin, _) ->
                        Set.insert tin s
                    )
                    existingIns
                    inputUtxos
            txForEval =
                tx
                    & bodyTxL . inputsTxBodyL
                        .~ allIns
        evalResult <- evaluateTx prov txForEval
        -- Check for script evaluation failures
        let failures =
                [ (p, e)
                | (p, Left e) <-
                    Map.toList evalResult
                ]
        if null failures
            then pure ()
            else
                error $
                    "evaluateAndBalance: \
                    \script eval failed: "
                        <> show failures
        -- Patch ExUnits from eval result
        let Redeemers rdmrMap =
                tx ^. witsTxL . rdmrsTxWitsL
            patched =
                Map.mapWithKey
                    ( \purpose (dat, eu) ->
                        case Map.lookup
                            purpose
                            evalResult of
                            Just (Right eu') ->
                                (dat, eu')
                            _ -> (dat, eu)
                    )
                    rdmrMap
            newRedeemers = Redeemers patched
            integrity =
                computeScriptIntegrity
                    lang
                    pp
                    newRedeemers
            patched' =
                tx
                    & witsTxL . rdmrsTxWitsL
                        .~ newRedeemers
                    & bodyTxL
                        . scriptIntegrityHashTxBodyL
                        .~ integrity
        case balanceTx
            pp
            inputUtxos
            changeAddr
            patched' of
            Left err ->
                error $
                    "evaluateAndBalance: "
                        <> show err
            Right br -> pure (balancedTx br)
