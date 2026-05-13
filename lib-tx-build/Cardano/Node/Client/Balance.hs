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
(@input + refunds - fee - deposits - outputs@)
and any residual multi-assets (@sum(input MA) +
mint - sum(existing output MA)@). This lets callers mint
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
    balanceTxWith,
    BalanceResult (..),
    CollateralUtxos (..),
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

import Data.Maybe (fromMaybe)
import Data.Sequence.Strict (StrictSeq, (|>))
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (
    Addr,
 )
import Cardano.Ledger.Alonzo.PParams (
    ppCollateralPercentageL,
 )
import Cardano.Ledger.Alonzo.TxWits (
    Redeemers (..),
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    collateralReturnTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    totalCollateralTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    rdmrsTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
    filterMultiAsset,
    mapMaybeMultiAsset,
 )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Deposits (bodyDepositDelta)
import Cardano.Node.Client.Inputs (spendingIndex)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Scripts (
    computeScriptIntegrity,
    evalBudgetExUnits,
    placeholderExUnits,
    refScriptsSize,
 )
import Cardano.Node.Client.Witnesses (estimatedKeyWitnessCount)

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
    | -- | Collateral inputs supply less lovelace than the
      --   protocol-required @ceil(fee × collateralPercent / 100)@.
      --   Carries @(required, available)@.
      CollateralShortfall !Coin !Coin
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
balanceTx pp inputUtxos refUtxos changeAddr =
    balanceTxWith
        pp
        inputUtxos
        (CollateralUtxos [])
        refUtxos
        changeAddr
        Nothing

{- | Newtype wrapper around the resolution map for
@collateral_inputs@. Distinct from @inputUtxos@ /
@refUtxos@ at the type level so the three positional
@[(TxIn, TxOut ConwayEra)]@ arguments to 'balanceTxWith'
cannot be transposed by accident.
-}
newtype CollateralUtxos = CollateralUtxos
    { unCollateralUtxos :: [(TxIn, TxOut ConwayEra)]
    }
    deriving (Eq, Show)

{- | Like 'balanceTx', but also populates the Conway
@total_collateral@ and @collateral_return@ body
fields whenever the tx has at least one redeemer
(a script witness) and at least one collateral
input. See issue #124.

The third argument is the resolution map for the
body's @collateral_inputs@ — the TxOuts the body
already references via 'collateral'. These UTxOs are
NOT added to @inputs@ (they only contribute lovelace
to the @total_collateral@ / @collateral_return@
arithmetic). When the same UTxO is used as both a
regular spend AND collateral, it's enough to list it
in @inputUtxos@: this function resolves collateral
lovelace from the union of both lists.

The fourth-from-last argument is an optional
override for the @collateral_return@ output's
address; when 'Nothing', the change address is
reused. When the body has no redeemers, both fields
stay absent — this preserves existing behaviour for
non-script flows.
-}
balanceTxWith ::
    PParams ConwayEra ->
    -- | Regular spend input UTxOs (added to the body).
    [(TxIn, TxOut ConwayEra)] ->
    -- | Collateral-only input UTxOs. Used to look up
    --     lovelace for @total_collateral@ /
    --     @collateral_return@ arithmetic; not added
    --     to the body's @inputs@. Pass @'CollateralUtxos' []@
    --     when no collateral resolution is needed
    --     (or when collateral UTxOs are already in
    --     @inputUtxos@ because they double as spends).
    CollateralUtxos ->
    [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    -- | Optional collateral-return address override.
    --     When 'Nothing', the change address is reused.
    Maybe Addr ->
    ConwayTx ->
    Either BalanceError BalanceResult
balanceTxWith
    pp
    inputUtxos
    (CollateralUtxos collateralUtxos)
    refUtxos
    changeAddr
    mCollReturnAddr
    tx =
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
            keyWitnesses =
                estimatedKeyWitnessCount body newInputs inputUtxos
            origOutputs = body ^. outputsTxBodyL
            -- Sum ADA / multi-assets already committed
            -- in existing outputs (e.g. asteria + ship
            -- outputs in a spawn-ship tx).
            (Coin origAda, origMA) = sumValues origOutputs
            depositDelta =
                bodyDepositDelta pp body
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
            bodyCollIns = body ^. collateralInputsTxBodyL
            hasRedeemers =
                let Redeemers rdmrs =
                        tx ^. witsTxL . rdmrsTxWitsL
                 in not (null rdmrs)
            -- Whether the tx requires explicit Conway
            -- collateral arithmetic (CIP-40).
            needsCollateralFields =
                not (Set.null bodyCollIns) && hasRedeemers
            -- Lovelace sum of the UTxOs referenced by the
            -- collateral input set. Resolved from the
            -- union of @collateralUtxos@ and @inputUtxos@
            -- (the same UTxO can legitimately appear in
            -- both, e.g. a fee UTxO that is also offered
            -- as collateral; 'Set'-deduplication of TxIns
            -- via the membership test prevents
            -- double-counting).
            collateralLovelace =
                let lookupSum =
                        foldl'
                            ( \(seen, Coin acc) (tin, o) ->
                                if Set.member tin bodyCollIns
                                    && not (Set.member tin seen)
                                    then
                                        let Coin c =
                                                o ^. coinTxOutL
                                         in ( Set.insert tin seen
                                            , Coin (acc + c)
                                            )
                                    else (seen, Coin acc)
                            )
                            (Set.empty, Coin 0)
                    (_, total) =
                        lookupSum (collateralUtxos ++ inputUtxos)
                 in total
            collReturnAddr = fromMaybe changeAddr mCollReturnAddr
            -- Compute total_collateral for a given fee:
            -- ceil(fee × collateralPercent / 100). The
            -- ledger requires this exact formula.
            collateralPercent :: Integer
            collateralPercent =
                fromIntegral (pp ^. ppCollateralPercentageL)
            ceilDiv a b = (a + b - 1) `div` b
            totalCollateralFor (Coin f) =
                Coin (ceilDiv (f * collateralPercent) 100)
            -- Apply the Conway collateral fields to a
            -- body (or leave them absent). Returns the
            -- result so the fee loop can spot a shortfall
            -- and abort.
            --
            -- Edge cases the ledger imposes:
            --   * @collateral_return@, when present, is
            --     subject to @minUtxo@ like any output;
            --     a tiny residual would be rejected with
            --     @BabbageOutputTooSmallUTxO@.
            --   * @total_collateral@ is a floor, not an
            --     exact amount — paying more is allowed.
            --
            -- So when the residual @avail − tc@ is below
            -- @minUtxo@, we fold it into @total_collateral@
            -- (consume the entire collateral, no return).
            -- This mirrors @cardano-cli transaction build@.
            applyCollateralFields f b =
                if needsCollateralFields
                    then
                        let requiredTc@(Coin tc) =
                                totalCollateralFor f
                            Coin avail = collateralLovelace
                            tentativeReturn residualCoin =
                                mkBasicTxOut
                                    collReturnAddr
                                    ( MaryValue
                                        residualCoin
                                        mempty
                                    )
                            residual = Coin (avail - tc)
                            minReturn =
                                getMinCoinTxOut
                                    pp
                                    (tentativeReturn residual)
                         in if avail < tc
                                then
                                    Left
                                        ( CollateralShortfall
                                            requiredTc
                                            collateralLovelace
                                        )
                                else
                                    if residual == Coin 0
                                        || residual < minReturn
                                        then
                                            -- Cannot emit a
                                            -- min-UTxO-valid
                                            -- collateral_return:
                                            -- consume the
                                            -- entire collateral
                                            -- input set as
                                            -- total_collateral.
                                            Right $
                                                b
                                                    & totalCollateralTxBodyL
                                                        .~ SJust collateralLovelace
                                                    & collateralReturnTxBodyL
                                                        .~ SNothing
                                        else
                                            Right $
                                                b
                                                    & totalCollateralTxBodyL
                                                        .~ SJust requiredTc
                                                    & collateralReturnTxBodyL
                                                        .~ SJust
                                                            (tentativeReturn residual)
                    else Right b
            -- Build a candidate tx for a given fee.
            -- Change is clamped to 0 so fee estimation
            -- works even when funds are insufficient.
            buildTx f =
                let Coin avail = inputCoin
                    Coin req = f
                    change =
                        max
                            0
                            (avail - req - origAda - depositDelta)
                    changeOut =
                        mkBasicTxOut
                            changeAddr
                            (MaryValue (Coin change) changeMA)
                    baseBody =
                        body
                            & inputsTxBodyL
                                .~ newInputs
                            & outputsTxBodyL
                                .~ ( origOutputs
                                        |> changeOut
                                   )
                            & feeTxBodyL .~ f
                 in case applyCollateralFields f baseBody of
                        Left err -> Left err
                        Right finalBody ->
                            Right (tx & bodyTxL .~ finalBody)
            -- Iterate until the fee stabilises. Returns
            -- the converged fee and the final candidate
            -- so the post-loop block reuses it instead
            -- of calling 'buildTx' once more.
            go !n currentFee
                | n > (10 :: Int) =
                    Left FeeNotConverged
                | otherwise =
                    case buildTx currentFee of
                        Left err -> Left err
                        Right candidate ->
                            let newFee =
                                    estimateMinFeeTx
                                        pp
                                        candidate
                                        keyWitnesses
                                        0 -- Byron witnesses
                                        refScriptBytes
                             in if newFee <= currentFee
                                    then
                                        Right
                                            (currentFee, candidate)
                                    else go (n + 1) newFee
            initFee = Coin 0
         in case go 0 initFee of
                Left err -> Left err
                Right (fee, result) ->
                    let Coin available = inputCoin
                        Coin required = fee
                        changeAmount =
                            available
                                - required
                                - origAda
                                - depositDelta
                     in if changeAmount < 0
                            then
                                Left
                                    ( InsufficientFee
                                        fee
                                        inputCoin
                                    )
                            else
                                Right
                                    ( BalanceResult
                                        result
                                        (length origOutputs)
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
