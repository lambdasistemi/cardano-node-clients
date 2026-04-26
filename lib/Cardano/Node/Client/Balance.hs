{-# LANGUAGE BangPatterns #-}

{- |
Module      : Cardano.Node.Client.Balance
Description : Simple transaction balancing
License     : Apache-2.0

Balance an unsigned Conway-era transaction by adding
fee-paying inputs and a change output. The fee is
estimated iteratively via 'estimateMinFeeTx' from
@cardano-ledger-api@ until the value converges
(at most 10 rounds). The function internally injects
dummy VKey witnesses for correct size estimation.

The change output absorbs both the residual ADA
(@input − fee − sum(existing output ADA)@) and any
residual multi-assets (@sum(input MA) + mint −
sum(existing output MA)@). This lets callers mint
NFTs without emitting an explicit recipient output:
the minted asset lands in the change output along
with the ADA leftovers, matching the convention of
mainnet off-chain code that returns the PILOT NFT in
the same output as the player's ADA change.

Multi-asset coin selection is still out of scope —
callers construct the script inputs and this module
only folds the leftover into a single change output.
-}
module Cardano.Node.Client.Balance (
    -- * Balancing
    balanceTx,
    BalanceResult (..),
    balanceFeeLoop,
    refScriptsSize,

    -- * Script helpers
    computeScriptIntegrity,
    spendingIndex,
    placeholderExUnits,
    evalBudgetExUnits,

    -- * Errors
    BalanceError (..),
    FeeLoopError (..),
) where

import Data.ByteString qualified as BS
import Data.Sequence.Strict (StrictSeq, (|>))
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.PParams (
    LangDepView,
    getLanguageView,
 )
import Cardano.Ledger.Alonzo.Tx (
    ScriptIntegrity (..),
    ScriptIntegrityHash,
    hashScriptIntegrity,
 )
import Cardano.Ledger.Alonzo.TxWits (
    Redeemers (..),
    TxDats (..),
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    mkBasicTxOut,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (originalBytes)
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
    filterMultiAsset,
    mapMaybeMultiAsset,
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (Language)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Ledger (ConwayTx)

{- | Result of 'balanceTx'. Carries the balanced
transaction and the index of the change output
(always the last output appended by 'balanceTx').
-}
data BalanceResult = BalanceResult
    { balancedTx :: !ConwayTx
    , changeIndex :: !Int
    }

-- | Errors from 'balanceTx'.
data BalanceError
    = -- | @InsufficientFee required available@
      InsufficientFee !Coin !Coin
    | -- | Fee did not converge within 10 iterations.
      FeeNotConverged
    deriving (Eq, Show)

{- | Balance a transaction by adding input UTxOs
and a change output.

One additional key witness is assumed for the fee
input. The fee is found by iterating
'estimateMinFeeTx' to a fixpoint: each round builds
the full transaction (with change output and fee
field set) and re-estimates until the fee stabilises.
'estimateMinFeeTx' internally pads the unsigned tx
with dummy VKey witnesses for correct size.
-}
balanceTx ::
    PParams ConwayEra ->
    -- | All input UTxOs to add (fee-paying and any
    --     script inputs not yet in the body). Their
    --     'TxIn's are unioned with the body's inputs.
    [(TxIn, TxOut ConwayEra)] ->
    -- | Resolved reference-input UTxOs whose
    --     'referenceScriptTxOutL' carries a Plutus
    --     script. Their byte sizes are passed to
    --     'estimateMinFeeTx' so the Conway
    --     @minFeeRefScriptCostPerByte@ tier is
    --     accounted for. Pass @[]@ if the tx has no
    --     reference scripts.
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    -- | Unbalanced transaction
    ConwayTx ->
    Either BalanceError BalanceResult
balanceTx pp inputUtxos refUtxos changeAddr tx =
    let body = tx ^. bodyTxL
        refScriptBytes =
            refScriptsSize
                (body ^. referenceInputsTxBodyL)
                refUtxos
        valueOf o = let MaryValue c m = o ^. valueTxOutL in (c, m)
        sumValues ::
            (Foldable t) =>
            t (TxOut ConwayEra) ->
            (Coin, MultiAsset)
        sumValues =
            foldl'
                ( \(Coin a, ma) o ->
                    let (Coin c, m) = valueOf o
                     in (Coin (a + c), ma <> m)
                )
                (Coin 0, mempty)
        (inputCoin, inputMA) = sumValues (map snd inputUtxos)
        newInputs =
            foldl'
                (\s (tin, _) -> Set.insert tin s)
                (body ^. inputsTxBodyL)
                inputUtxos
        origOutputs = body ^. outputsTxBodyL
        -- Sum ADA / multi-assets already committed
        -- in existing outputs (e.g. asteria + ship
        -- outputs in a spawn-ship tx).
        (Coin origAda, origMA) = sumValues origOutputs
        bodyMint :: MultiAsset
        bodyMint = body ^. mintTxBodyL
        -- Residual multi-assets that no existing
        -- output absorbed: input + mint − output.
        -- A positive residual indicates minted tokens
        -- (e.g. a PILOT NFT) or unspent input assets
        -- that must land in the change output to
        -- satisfy the ledger's value-conservation
        -- equation.
        --
        -- Negative entries — output references assets
        -- the balancer wasn't told about — are
        -- filtered out: the caller has already
        -- balanced those via inputs not surfaced in
        -- @inputUtxos@, and the ledger checks
        -- conservation against the real UTxO state
        -- at submission time.
        changeMA :: MultiAsset
        changeMA =
            filterMultiAsset
                (\_ _ q -> q > 0)
                ( inputMA
                    <> bodyMint
                    <> mapMaybeMultiAsset
                        (\_ _ q -> Just (negate q))
                        origMA
                )
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
                        (MaryValue (Coin change) changeMA)
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
                Left FeeNotConverged
            | otherwise =
                let candidate =
                        buildTx currentFee
                    newFee =
                        estimateMinFeeTx
                            pp
                            candidate
                            1 -- key witnesses
                            0 -- Byron witnesses
                            refScriptBytes
                 in if newFee <= currentFee
                        then Right currentFee
                        else go (n + 1) newFee
        initFee = Coin 0
     in case go 0 initFee of
            Left err -> Left err
            Right fee ->
                let Coin available = inputCoin
                    Coin required = fee
                    changeAmount =
                        available - required - origAda
                 in if changeAmount < 0
                        then
                            Left
                                ( InsufficientFee
                                    fee
                                    inputCoin
                                )
                        else
                            let result = buildTx fee
                                chIdx =
                                    length origOutputs
                             in Right
                                    ( BalanceResult
                                        result
                                        chIdx
                                    )

{- | Output function rejected the fee, or the
iteration did not converge.
-}
data FeeLoopError
    = -- | Fee did not converge in 10 iterations.
      FeeDidNotConverge
    | -- | The output function returned an error
      --       (e.g., insufficient funds for the fee).
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
    --     'Left' to abort (e.g., fee exceeds
    --     available funds).
    (Coin -> Either String (StrictSeq (TxOut ConwayEra))) ->
    -- | Number of key witnesses to assume for
    --     fee estimation.
    Int ->
    -- | Resolved reference-input UTxOs (see
    --     'balanceTx'). Pass @[]@ if the tx has no
    --     reference scripts.
    [(TxIn, TxOut ConwayEra)] ->
    -- | Template transaction.
    ConwayTx ->
    Either FeeLoopError ConwayTx
balanceFeeLoop pp mkOutputs numWitnesses refUtxos tx =
    go 0 (Coin 0)
  where
    refScriptBytes =
        refScriptsSize
            (tx ^. bodyTxL . referenceInputsTxBodyL)
            refUtxos
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
                                refScriptBytes
                     in if newFee <= currentFee
                            then Right candidate
                            else go (n + 1) newFee

{- | Sum the byte lengths of any reference scripts
attached to UTxOs whose 'TxIn' is in the body's
@referenceInputsTxBodyL@ set. Used to feed
@estimateMinFeeTx@ so the Conway
@minFeeRefScriptCostPerByte@ tier is correctly
charged.

Native (timelock) scripts are included in the sum;
the Conway ledger only charges Plutus scripts, so
including timelock bytes can over-estimate slightly,
which is safe — over-paying fee is accepted by the
ledger; under-paying is rejected with
@FeeTooSmallUTxO@.
-}
refScriptsSize ::
    Set.Set TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    Int
refScriptsSize bodyRefIns =
    foldr
        ( \(i, o) acc ->
            if Set.member i bodyRefIns
                then case o ^. referenceScriptTxOutL of
                    SJust s -> acc + BS.length (originalBytes s)
                    SNothing -> acc
                else acc
        )
        0

-- -----------------------------------------------------------
-- Script helpers
-- -----------------------------------------------------------

{- | Compute the 'ScriptIntegrityHash' from protocol
parameters, a set of 'Redeemers', and the Plutus
language used.

The hash covers the language cost model, redeemers,
and an empty datum set (inline datums only — no
datum map needed).

@
integrity <- computeScriptIntegrity PlutusV3 pp redeemers
body & scriptIntegrityHashTxBodyL .~ integrity
@
-}
computeScriptIntegrity ::
    Language ->
    PParams ConwayEra ->
    Redeemers ConwayEra ->
    StrictMaybe ScriptIntegrityHash
computeScriptIntegrity lang pp rdmrs =
    let langViews :: Set.Set LangDepView
        langViews =
            Set.singleton
                (getLanguageView pp lang)
        emptyDats :: TxDats ConwayEra
        emptyDats = TxDats mempty
        Redeemers redeemerMap = rdmrs
     in if null redeemerMap && null langViews
            then SNothing
            else
                SJust $
                    hashScriptIntegrity $
                        ScriptIntegrity rdmrs emptyDats langViews

{- | Compute the spending index of a 'TxIn' within
the sorted input set.

Plutus spending redeemers reference inputs by their
position in the sorted set of all transaction
inputs. This function finds that position.

@
let allInputs = Set.fromList [stateIn, reqIn, feeIn]
    stateIx = spendingIndex stateIn allInputs
    -- redeemer: ConwaySpending (AsIx stateIx)
@
-}
spendingIndex :: TxIn -> Set.Set TxIn -> Word32
spendingIndex needle inputs =
    let sorted = Set.toAscList inputs
     in go 0 sorted
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs

{- | Zero execution units, used as placeholder when
building a transaction before script evaluation.
After calling 'evaluateTx', patch the redeemers
with the real values.
-}
placeholderExUnits :: ExUnits
placeholderExUnits = ExUnits 0 0

{- | Max-budget execution units for script
evaluation. The ledger evaluator uses redeemer
ExUnits as the execution budget; scripts that
exceed the budget are terminated. This value is
injected before 'evaluateTx' so scripts get
enough room to run, then replaced by the real
ExUnits from the evaluation result.
-}
evalBudgetExUnits :: ExUnits
evalBudgetExUnits = ExUnits 14_000_000 10_000_000_000
