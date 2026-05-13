{- |
Module      : Cardano.Node.Client.Scripts
Description : Script fee and integrity helpers
License     : Apache-2.0

Helpers for script-related transaction body concepts
used by builders and balancers.
-}
module Cardano.Node.Client.Scripts (
    computeScriptIntegrity,
    evalBudgetExUnits,
    placeholderExUnits,
    refScriptsSize,
) where

import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Lens.Micro ((^.))

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
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (originalBytes)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (Language)
import Cardano.Ledger.TxIn (TxIn)

{- | Sum the byte lengths of any reference scripts
attached to UTxOs whose 'TxIn' is in the body's
@referenceInputsTxBodyL@ set. Used to feed
@estimateMinFeeTx@ so the Conway
@minFeeRefScriptCostPerByte@ tier is correctly
charged.

Native (timelock) scripts are included in the sum;
the Conway ledger only charges Plutus scripts, so
including timelock bytes can over-estimate slightly,
which is safe: over-paying fee is accepted by the
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

{- | Compute the 'ScriptIntegrityHash' from protocol
parameters, a set of 'Redeemers', and the Plutus
language used.

The hash covers the language cost model, redeemers,
and an empty datum set (inline datums only, no datum
map needed).
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

{- | Zero execution units, used as placeholder when
building a transaction before script evaluation.
After calling @evaluateTx@, patch the redeemers
with the real values.
-}
placeholderExUnits :: ExUnits
placeholderExUnits = ExUnits 0 0

{- | Max-budget execution units for script
evaluation. The ledger evaluator uses redeemer
ExUnits as the execution budget; scripts that
exceed the budget are terminated. This value is
injected before @evaluateTx@ so scripts get enough
room to run, then replaced by the real ExUnits from
the evaluation result.

Sized to mainnet's Conway-era @maxTxExUnits@
(epoch 627+: 16_500_000 mem, 10_000_000_000
steps), so heavy scripts that already run on
mainnet fit under the eval budget locally too.
Submission fails the same way as it would on
mainnet if a script's actual usage exceeds the
cluster's pp.
-}
evalBudgetExUnits :: ExUnits
evalBudgetExUnits = ExUnits 16_500_000 10_000_000_000
