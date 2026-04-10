{-# LANGUAGE BangPatterns #-}

{- |
Module      : Cardano.Node.Client.Balance
Description : Simple transaction balancing
License     : Apache-2.0

Balance an unsigned Conway-era transaction by adding
fee-paying inputs and a change output. The fee is
estimated iteratively via 'estimateMinFeeTx' from
@cardano-ledger-api@ until the value converges
(at most 10 rounds).

This is a simplified balancer that only handles
ADA-only fee inputs. Multi-asset coin selection is
out of scope — callers construct the script inputs
and this module adds the fee delta.
-}
module Cardano.Node.Client.Balance (
    -- * Balancing
    balanceTx,
    balanceFeeLoop,

    -- * Errors
    BalanceError (..),
    FeeLoopError (..),
) where

import Data.Foldable (foldl')
import Data.Sequence.Strict (StrictSeq, (|>))
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (
    Tx,
    bodyTxL,
    estimateMinFeeTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.TxIn (TxIn)

-- | Fee-paying UTxO has insufficient ada.
data BalanceError
    = -- | @InsufficientFee required available@
      InsufficientFee !Coin !Coin
    deriving (Eq, Show)

{- | Balance a transaction by adding input UTxOs
and a change output.

One additional key witness is assumed for the fee
input. The fee is found by iterating
'setMinFeeTx' to a fixpoint: each round builds
the full transaction (with change output and fee
field set) and re-estimates until the fee
stabilises.
-}
balanceTx ::
    PParams ConwayEra ->
    {- | All input UTxOs to add (fee-paying and any
    script inputs not yet in the body). Their
    'TxIn's are unioned with the body's inputs.
    -}
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    -- | Unbalanced transaction
    Tx ConwayEra ->
    Either BalanceError (Tx ConwayEra)
balanceTx pp inputUtxos changeAddr tx =
    let body = tx ^. bodyTxL
        inputCoin =
            foldl'
                ( \(Coin acc) (_, o) ->
                    let Coin c = o ^. coinTxOutL
                     in Coin (acc + c)
                )
                (Coin 0)
                inputUtxos
        newInputs =
            foldl'
                (\s (tin, _) -> Set.insert tin s)
                (body ^. inputsTxBodyL)
                inputUtxos
        origOutputs = body ^. outputsTxBodyL
        -- Sum ADA already committed in existing
        -- outputs (e.g. cage output with 2 ADA).
        Coin origAda =
            foldl'
                ( \(Coin acc) o ->
                    let Coin c = o ^. coinTxOutL
                     in Coin (acc + c)
                )
                (Coin 0)
                origOutputs
        -- Build a candidate tx for a given fee.
        -- Change is clamped to 0 so fee estimation
        -- works even when funds are insufficient.
        buildTx f =
            let Coin avail = inputCoin
                Coin req = f
                change =
                    max
                        0
                        (avail - req - origAda)
                changeOut =
                    mkBasicTxOut
                        changeAddr
                        (inject (Coin change))
                finalBody =
                    body
                        & inputsTxBodyL
                            .~ newInputs
                        & outputsTxBodyL
                            .~ ( origOutputs
                                    |> changeOut
                               )
                        & feeTxBodyL .~ f
             in tx & bodyTxL .~ finalBody
        -- Iterate until the fee stabilises.
        go !n currentFee
            | n > (10 :: Int) =
                error
                    "balanceTx: fee did not \
                    \converge in 10 iterations"
            | otherwise =
                let candidate =
                        buildTx currentFee
                    newFee =
                        estimateMinFeeTx
                            pp
                            candidate
                            1 -- key witnesses
                            0 -- Byron witnesses
                            0 -- ref scripts bytes
                 in if newFee <= currentFee
                        then currentFee
                        else go (n + 1) newFee
        initFee = Coin 0
        fee = go 0 initFee
        Coin available = inputCoin
        Coin required = fee
        changeAmount =
            available - required - origAda
     in if changeAmount < 0
            then
                Left (InsufficientFee fee inputCoin)
            else Right (buildTx fee)

-- | Output function rejected the fee, or the
-- iteration did not converge.
data FeeLoopError
    = -- | Fee did not converge in 10 iterations.
      FeeDidNotConverge
    | -- | The output function returned an error
      --   (e.g., insufficient funds for the fee).
      OutputError !String
    deriving (Eq, Show)

{- | Find the fee fixed point for a transaction
where output values depend on the fee.

In standard balancing ('balanceTx'), outputs are
fixed and only the fee varies. Some validators
enforce conservation equations like:

@sum(refunds) = sum(inputs) - fee - N * tip@

where the refund output values depend on the fee.
This creates a circular dependency: the fee depends
on the tx size, which depends on the output values,
which depend on the fee.

'balanceFeeLoop' breaks this cycle by iterating:

1. Compute outputs for the current fee estimate
2. Build the tx with those outputs and fee
3. Re-estimate the fee from the tx size
4. If the fee changed, go to (1)

Convergence is fast (2–3 rounds) because a fee
change of @Δf@ changes output CBOR encoding by at
most a few bytes, which changes the fee by
@≈ a × (bytes changed)@ lovelace — well under @Δf@.

The template transaction must have inputs,
collateral, scripts, and redeemers already set.
The fee and outputs will be overwritten.

Unlike 'balanceTx', this does NOT add inputs or a
change output. The fee is paid from the existing
inputs; any excess (converged fee minus minimum)
goes to the Cardano treasury.

@
  let mkOutputs fee =
        let refund = inputValue - fee - tip
        in  Right [stateOutput, mkRefundOutput refund]
  in  balanceFeeLoop pp mkOutputs 1 templateTx
@
-}
balanceFeeLoop ::
    PParams ConwayEra ->
    -- | Compute outputs for a given fee. Return
    --   'Left' to abort (e.g., fee exceeds
    --   available funds).
    (Coin -> Either String (StrictSeq (TxOut ConwayEra))) ->
    -- | Number of key witnesses to assume for
    --   fee estimation.
    Int ->
    -- | Template transaction.
    Tx ConwayEra ->
    Either FeeLoopError (Tx ConwayEra)
balanceFeeLoop pp mkOutputs numWitnesses tx =
    go 0 (Coin 0)
  where
    go !n currentFee
        | n > (10 :: Int) = Left FeeDidNotConverge
        | otherwise =
            case mkOutputs currentFee of
                Left msg -> Left (OutputError msg)
                Right outs ->
                    let candidate =
                            tx
                                & bodyTxL . outputsTxBodyL
                                    .~ outs
                                & bodyTxL . feeTxBodyL
                                    .~ currentFee
                        newFee =
                            estimateMinFeeTx
                                pp
                                candidate
                                numWitnesses
                                0 -- boot witnesses
                                0 -- ref scripts bytes
                     in if newFee <= currentFee
                            then Right candidate
                            else go (n + 1) newFee
