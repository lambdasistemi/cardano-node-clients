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
    Check (..),
    LedgerCheck (..),

    -- * Interpreters
    Interpret (..),
    InterpretIO (..),

    -- * Witnesses
    SpendWitness (..),
    MintWitness (..),
    WithdrawWitness (..),

    -- * Input combinators
    spend,
    spendScript,
    reference,
    collateral,

    -- * Output combinators
    payTo,
    payTo',
    output,

    -- * Minting
    mint,

    -- * Withdrawals and metadata
    withdraw,
    withdrawScript,
    setMetadata,

    -- * Constraints
    validFrom,
    validTo,
    requireSignature,
    attachScript,

    -- * Deferred
    peek,
    valid,
    ctx,

    -- * Checkers
    checkMinUtxo,
    checkTxSize,

    -- * Assembly
    draft,
    draftWith,
    build,

    -- * Errors
    BuildError (..),

    -- * Internal (for testing)
    interpretWith,
    assembleTx,
    bumpFee,
) where

import Cardano.Binary (serialize')
import Control.Monad.Operational (
    Program,
    ProgramViewT (Return, (:>>=)),
    singleton,
    view,
 )
import Data.ByteString qualified as BS
import Data.Foldable (foldl')
import Data.Functor.Identity (
    runIdentity,
 )
import Data.List (elemIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Cardano.Ledger.Address (
    Addr,
    RewardAccount,
    Withdrawals (..),
 )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.PParams (getLanguageView)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx (hashScriptIntegrity)
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Alonzo.TxWits (
    Redeemers (..),
    TxDats (..),
 )
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    dataToBinaryData,
 )
import Cardano.Ledger.Api.Tx (
    Tx,
    auxDataTxL,
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.Api.Tx.Wits (
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (
    PParams,
    Script,
    auxDataHashTxBodyL,
    hashScript,
    hashTxAuxData,
    metadataTxAuxDataL,
    mkBasicTxAuxData,
 )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (..),
 )
import Cardano.Ledger.Mary.Value (
    AssetName,
    MaryValue,
    MultiAsset (..),
    PolicyID,
 )
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
 )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Balance (
    BalanceError,
    balanceTx,
 )
import Cardano.Slotting.Slot (SlotNo)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (ToData (..))

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

-- | Validation result for the final transaction.
data Check e
    = -- | Validation passed.
      Pass
    | -- | One of the library-provided checks failed.
      LedgerFail LedgerCheck
    | -- | A user-provided check failed.
      CustomFail e
    deriving (Show, Eq)

-- | Closed set of library-provided validation failures.
data LedgerCheck
    = MinUtxoViolation Word32 Coin Coin
    | TxSizeExceeded Natural Natural
    | ValueNotConserved MaryValue MaryValue
    | CollateralInsufficient Coin Coin
    deriving (Show, Eq)

-- | How a spent input is witnessed.
data SpendWitness
    = -- | Pub-key input, no redeemer needed.
      PubKeyWitness
    | -- | Script input with a typed redeemer.
      forall r. (ToData r) => ScriptWitness r

-- | How a minting operation is witnessed.
data MintWitness
    = -- | Plutus script with a typed redeemer.
      forall r. (ToData r) => PlutusScriptWitness r

-- | How a withdrawal is witnessed.
data WithdrawWitness
    = -- | Pub-key withdrawal, no redeemer needed.
      PubKeyWithdraw
    | -- | Script withdrawal with a typed redeemer.
      forall r. (ToData r) => ScriptWithdraw r

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
    -- | Add a reference input.
    Reference :: TxIn -> TxInstr q e ()
    -- | Add a collateral input.
    Collateral :: TxIn -> TxInstr q e ()
    -- | Add an output.
    Send ::
        TxOut ConwayEra -> TxInstr q e ()
    -- | Mint or burn tokens.
    MintI ::
        PolicyID ->
        AssetName ->
        Integer ->
        MintWitness ->
        TxInstr q e ()
    -- | Withdraw stake rewards.
    Withdraw ::
        RewardAccount ->
        Coin ->
        WithdrawWitness ->
        TxInstr q e ()
    -- | Set transaction metadata for a label.
    SetMetadata ::
        Word64 ->
        Metadatum ->
        TxInstr q e ()
    -- | Require a key signature.
    ReqSignature ::
        KeyHash 'Witness -> TxInstr q e ()
    -- | Attach a Plutus script.
    AttachScript ::
        Script ConwayEra -> TxInstr q e ()
    -- | Set the lower validity bound.
    SetValidFrom :: SlotNo -> TxInstr q e ()
    -- | Set the upper validity bound.
    SetValidTo :: SlotNo -> TxInstr q e ()
    -- | Peek at the final Tx (fixpoint).
    Peek ::
        (Tx ConwayEra -> Convergence a) ->
        TxInstr q e a
    -- | Validate the final Tx after convergence.
    Valid ::
        (Tx ConwayEra -> Check e) ->
        TxInstr q e ()
    -- | Query external context.
    Ctx :: q a -> TxInstr q e a

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

{- | Spend a script UTxO with a typed redeemer.
Returns the spending index.
-}
spendScript ::
    (ToData r) => TxIn -> r -> TxBuild q e Word32
spendScript txIn r = do
    singleton $ Spend txIn (ScriptWitness r)
    singleton $ Peek $ \tx ->
        let ins = tx ^. bodyTxL . inputsTxBodyL
         in if Set.member txIn ins
                then Ok (spendingIndex txIn ins)
                else Iterate 0

-- | Add a reference input.
reference :: TxIn -> TxBuild q e ()
reference = singleton . Reference

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

{- | Pay value with a typed inline datum.
Returns the output index.
-}
payTo' ::
    (ToData d) =>
    Addr ->
    MaryValue ->
    d ->
    TxBuild q e Word32
payTo' addr val datum = do
    singleton $
        Send $
            mkBasicTxOut addr val
                & datumTxOutL
                    .~ mkInlineDatum (toPlcData datum)
    singleton $ Peek $ \tx ->
        let outs = tx ^. bodyTxL . outputsTxBodyL
            target =
                mkBasicTxOut addr val
                    & datumTxOutL
                        .~ mkInlineDatum
                            (toPlcData datum)
         in case elemIndex target (toList outs) of
                Just i -> Ok (fromIntegral i)
                Nothing -> Iterate 0
  where
    toList = foldr (:) []

{- | Mint or burn tokens. Positive = mint,
negative = burn. Zero-amount entries are skipped.
-}
mint ::
    (ToData r) =>
    PolicyID ->
    Map AssetName Integer ->
    r ->
    TxBuild q e ()
mint pid assets r =
    mapM_
        ( \(name, qty) ->
            singleton $
                MintI pid name qty (PlutusScriptWitness r)
        )
        [ (n, q)
        | (n, q) <- Map.toList assets
        , q /= 0
        ]

-- | Withdraw stake rewards from a pub-key account.
withdraw :: RewardAccount -> Coin -> TxBuild q e ()
withdraw rewardAccount amount =
    singleton $ Withdraw rewardAccount amount PubKeyWithdraw

-- | Withdraw stake rewards from a script-backed account.
withdrawScript ::
    (ToData r) =>
    RewardAccount ->
    Coin ->
    r ->
    TxBuild q e ()
withdrawScript rewardAccount amount redeemer =
    singleton $
        Withdraw
            rewardAccount
            amount
            (ScriptWithdraw redeemer)

-- | Set transaction metadata for a label.
setMetadata :: Word64 -> Metadatum -> TxBuild q e ()
setMetadata label = singleton . SetMetadata label

-- | Set the lower validity bound.
validFrom :: SlotNo -> TxBuild q e ()
validFrom = singleton . SetValidFrom

-- | Set the upper validity bound.
validTo :: SlotNo -> TxBuild q e ()
validTo = singleton . SetValidTo

-- | Require a key signature.
requireSignature ::
    KeyHash 'Witness -> TxBuild q e ()
requireSignature = singleton . ReqSignature

-- | Attach a Plutus script to the transaction.
attachScript :: Script ConwayEra -> TxBuild q e ()
attachScript = singleton . AttachScript

-- | Peek at the final assembled Tx.
peek ::
    (Tx ConwayEra -> Convergence a) ->
    TxBuild q e a
peek = singleton . Peek

-- | Validate the final converged transaction.
valid ::
    (Tx ConwayEra -> Check e) ->
    TxBuild q e ()
valid = singleton . Valid

-- | Query pluggable build context.
ctx :: q a -> TxBuild q e a
ctx = singleton . Ctx

-- | Check that the indexed output meets the min-UTxO threshold.
checkMinUtxo ::
    PParams ConwayEra ->
    Word32 ->
    TxBuild q e ()
checkMinUtxo pp outIx =
    valid $ \tx ->
        case txOutAt outIx (tx ^. bodyTxL . outputsTxBodyL) of
            Nothing -> Pass
            Just txOut ->
                let actual = txOut ^. coinTxOutL
                    required = getMinCoinTxOut pp txOut
                 in if actual >= required
                        then Pass
                        else
                            LedgerFail $
                                MinUtxoViolation
                                    outIx
                                    actual
                                    required

-- | Check that the CBOR-encoded transaction fits within max size.
checkTxSize :: PParams ConwayEra -> TxBuild q e ()
checkTxSize pp =
    valid $ \tx ->
        let actual =
                fromIntegral $
                    BS.length $
                        serialize' tx
            limit =
                fromIntegral $
                    pp ^. ppMaxTxSizeL
         in if actual <= limit
                then Pass
                else
                    LedgerFail $
                        TxSizeExceeded actual limit

-- ----------------------------------------------------
-- Interpreter state
-- ----------------------------------------------------

-- | Accumulated state from interpreting 'TxBuild'.
data TxState e = TxState
    { tsSpends :: [(TxIn, SpendWitness)]
    , tsRefIns :: [TxIn]
    , tsCollIns :: [TxIn]
    , tsOuts :: [TxOut ConwayEra]
    , tsMints ::
        [ ( PolicyID
          , AssetName
          , Integer
          , MintWitness
          )
        ]
    , tsWithdrawals ::
        [(RewardAccount, Coin, WithdrawWitness)]
    , tsMetadata :: Map Word64 Metadatum
    , tsSigners :: Set (KeyHash 'Witness)
    , tsScripts ::
        Map ScriptHash (Script ConwayEra)
    , tsValidFrom :: StrictMaybe SlotNo
    , tsValidTo :: StrictMaybe SlotNo
    , tsChecks :: [Tx ConwayEra -> Check e]
    }

emptyState :: TxState e
emptyState =
    TxState
        { tsSpends = []
        , tsRefIns = []
        , tsCollIns = []
        , tsOuts = []
        , tsMints = []
        , tsWithdrawals = []
        , tsMetadata = Map.empty
        , tsSigners = Set.empty
        , tsScripts = Map.empty
        , tsValidFrom = SNothing
        , tsValidTo = SNothing
        , tsChecks = []
        }

{- | Interpret a 'TxBuild' program into 'TxState'.
The 'Tx' argument resolves 'Peek' nodes.
-}
interpretWith ::
    Interpret q ->
    Tx ConwayEra ->
    TxBuild q e a ->
    -- | (state, result, all converged?)
    (TxState e, a, Bool)
interpretWith interpret currentTx prog =
    runIdentity $
        interpretWithM
            (pure . runInterpret interpret)
            currentTx
            prog

interpretWithM ::
    (Monad m) =>
    (forall x. q x -> m x) ->
    Tx ConwayEra ->
    TxBuild q e a ->
    m (TxState e, a, Bool)
interpretWithM runCtx currentTx = go emptyState True
  where
    go st conv prog = case view prog of
        Return a -> pure (st, a, conv)
        Spend txIn w :>>= k ->
            go
                st
                    { tsSpends =
                        tsSpends st ++ [(txIn, w)]
                    }
                conv
                (k ())
        Reference txIn :>>= k ->
            go
                st
                    { tsRefIns =
                        tsRefIns st ++ [txIn]
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
        MintI pid name qty w :>>= k ->
            go
                st
                    { tsMints =
                        tsMints st
                            ++ [(pid, name, qty, w)]
                    }
                conv
                (k ())
        Withdraw rewardAccount amount w :>>= k ->
            go
                st
                    { tsWithdrawals =
                        tsWithdrawals st
                            ++ [(rewardAccount, amount, w)]
                    }
                conv
                (k ())
        SetMetadata label metadatum :>>= k ->
            go
                st
                    { tsMetadata =
                        Map.insert
                            label
                            metadatum
                            (tsMetadata st)
                    }
                conv
                (k ())
        ReqSignature kh :>>= k ->
            go
                st
                    { tsSigners =
                        Set.insert kh (tsSigners st)
                    }
                conv
                (k ())
        AttachScript script :>>= k ->
            go
                st
                    { tsScripts =
                        Map.insert
                            (hashScript script)
                            script
                            (tsScripts st)
                    }
                conv
                (k ())
        SetValidFrom slot :>>= k ->
            go
                st
                    { tsValidFrom = SJust slot
                    }
                conv
                (k ())
        SetValidTo slot :>>= k ->
            go
                st
                    { tsValidTo = SJust slot
                    }
                conv
                (k ())
        Peek f :>>= k ->
            case f currentTx of
                Ok a -> go st conv (k a)
                Iterate a ->
                    go st False (k a)
        Valid chk :>>= k ->
            go
                st
                    { tsChecks =
                        tsChecks st ++ [chk]
                    }
                conv
                (k ())
        Ctx q :>>= k -> do
            a <- runCtx q
            go st conv (k a)

-- | Assemble a 'Tx' from interpreter state.
assembleTx :: PParams ConwayEra -> TxState e -> Tx ConwayEra
assembleTx = assembleTxWith Set.empty

{- | Assemble with extra input TxIns (e.g. fee UTxO).
These are included in the input set for correct
spending index computation but don't get redeemers.
-}
assembleTxWith ::
    Set.Set TxIn -> PParams ConwayEra -> TxState e -> Tx ConwayEra
assembleTxWith extraIns pp st =
    let
        allSpendIns =
            Set.union extraIns $
                Set.fromList $
                    map fst (tsSpends st)
        refIns = Set.fromList (tsRefIns st)
        collIns = Set.fromList (tsCollIns st)
        outs = StrictSeq.fromList (tsOuts st)
        mintMA = foldl' addMint mempty (tsMints st)
        withdrawalEntries =
            collectWithdrawalEntries
                (tsWithdrawals st)
        withdrawals =
            Withdrawals
                (Map.map fst withdrawalEntries)
        -- Build redeemers
        spendRdmrs =
            collectSpendRedeemers
                allSpendIns
                (tsSpends st)
        mintRdmrs = collectMintRedeemers (tsMints st)
        withdrawalRdmrs =
            collectWithdrawalRedeemers
                withdrawals
                withdrawalEntries
        rdmrList =
            spendRdmrs
                ++ mintRdmrs
                ++ withdrawalRdmrs
        allRdmrs = Redeemers $ Map.fromList rdmrList
        auxData =
            if Map.null (tsMetadata st)
                then SNothing
                else
                    SJust $
                        mkBasicTxAuxData
                            & metadataTxAuxDataL
                                .~ tsMetadata st
        -- Integrity hash (skip if no scripts)
        integrity =
            if null rdmrList
                then SNothing
                else
                    hashScriptIntegrity
                        ( Set.singleton
                            (getLanguageView pp PlutusV3)
                        )
                        allRdmrs
                        (TxDats mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ allSpendIns
                & outputsTxBodyL .~ outs
                & referenceInputsTxBodyL .~ refIns
                & collateralInputsTxBodyL .~ collIns
                & mintTxBodyL .~ mintMA
                & withdrawalsTxBodyL .~ withdrawals
                & reqSignerHashesTxBodyL
                    .~ tsSigners st
                & vldtTxBodyL
                    .~ ValidityInterval
                        { invalidBefore = tsValidFrom st
                        , invalidHereafter = tsValidTo st
                        }
                & auxDataHashTxBodyL
                    .~ fmap hashTxAuxData auxData
                & scriptIntegrityHashTxBodyL
                    .~ integrity
     in
        mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ tsScripts st
            & witsTxL . rdmrsTxWitsL
                .~ allRdmrs
            & auxDataTxL
                .~ auxData

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
draft pp = draftWith pp noCtxInterpret

noCtxInterpret :: Interpret q
noCtxInterpret =
    Interpret $
        const $
            error
                "draft: encountered ctx without draftWith interpreter"

draftWith ::
    PParams ConwayEra ->
    Interpret q ->
    TxBuild q e a ->
    Tx ConwayEra
draftWith pp interpret prog =
    let
        -- Pass 1: collect steps with bogus Tx
        initialTx = mkBasicTx mkBasicTxBody
        (st1, _, _) =
            interpretWith interpret initialTx prog
        -- Assemble from pass 1
        tx1 = assembleTx pp st1
        -- Pass 2: re-interpret with real Tx for
        -- Peek resolution
        (st2, _, _) =
            interpretWith interpret tx1 prog
     in
        assembleTx pp st2

-- | Errors from 'build'.
data BuildError e
    = -- | Script evaluation failure.
      EvalFailure
        (ConwayPlutusPurpose AsIx ConwayEra)
        String
    | -- | Balance failure.
      BalanceFailed BalanceError
    | -- | Validation failures on the final Tx.
      ChecksFailed [Check e]
    deriving (Show)

{- | Assemble, evaluate scripts, and balance.

Iterates until all 'Peek' nodes return 'Ok' and
the Tx body stabilizes:

1. Interpret program with current Tx (resolve Peek)
2. Assemble Tx from steps
3. Add input UTxOs, evaluate scripts → ExUnits
4. Patch redeemers, recompute integrity hash
5. Balance (fee + change)
6. If any Peek returned Iterate or Tx changed → 1
-}
build ::
    PParams ConwayEra ->
    InterpretIO q ->
    -- | Script evaluator
    ( Tx ConwayEra ->
      IO
        ( Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
    ) ->
    -- | All input UTxOs
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    TxBuild q e a ->
    IO (Either (BuildError e) (Tx ConwayEra))
build pp interpret evaluateTx inputUtxos changeAddr prog =
    step Set.empty (Coin 0) (mkBasicTx mkBasicTxBody)
  where
    -- Pre-compute the extra TxIns from inputUtxos
    -- so Peek-based index computation sees ALL
    -- inputs (including fee UTxO).
    extraIns =
        Set.fromList $ map fst inputUtxos
    addExtras tx =
        let existing =
                tx ^. bodyTxL . inputsTxBodyL
         in tx
                & bodyTxL . inputsTxBodyL
                    .~ Set.union existing extraIns

    -- \| One iteration: interpret, assemble, eval,
    -- patch, balance. Track seen fees to detect
    -- oscillation and bisect.
    step seenFees maxFee prevTx = do
        -- 1. Interpret
        let prevWithIns = addExtras prevTx
        (st, _, _) <-
            interpretWithM
                (runInterpretIO interpret)
                prevWithIns
                prog
        let tx = assembleTxWith extraIns pp st
            prevFee = prevTx ^. bodyTxL . feeTxBodyL
            txForEval =
                tx & bodyTxL . feeTxBodyL .~ prevFee
        -- 2. Eval (no change output; scripts that
        --    check conservation use tx.fee which
        --    matches Peek-computed outputs).
        evalResult <- evaluateTx txForEval
        let failures =
                [ (p, e)
                | (p, Left e) <-
                    Map.toList evalResult
                ]
            evalEUs =
                [ (show p, show eu)
                | (p, Right eu) <-
                    Map.toList evalResult
                ]
            Redeemers assembledRdmrs =
                tx ^. witsTxL . rdmrsTxWitsL
            assembledEUs =
                [ (show p, show eu)
                | (p, (_, eu)) <-
                    Map.toList assembledRdmrs
                ]
        appendFile "/tmp/txbuild-debug.log"
            $ "STEP: prevFee="
                <> show prevFee
                <> " assembled-EUs="
                <> show assembledEUs
                <> " eval-EUs="
                <> show evalEUs
                <> " failures="
                <> show (length failures)
                <> "\n"
        case failures of
            ((_, _) : _) -> do
                -- Eval failed. Retry with estimate.
                let estFee =
                        estimateMinFeeTx
                            pp
                            txForEval
                            1
                            0
                            0
                appendFile "/tmp/txbuild-debug.log"
                    $ "EVAL-FAIL: estFee="
                        <> show estFee
                        <> " errors="
                        <> show
                            (map snd failures)
                        <> "\n"
                let retryTx =
                        tx
                            & bodyTxL . feeTxBodyL
                                .~ estFee
                step seenFees maxFee retryTx
            [] -> do
                -- 3. Patch ExUnits THEN balance.
                --    This way balanceTx sees the
                --    real script cost.
                let patchedTx =
                        patchExUnits tx evalResult
                    Redeemers patchedRdmrs =
                        patchedTx
                            ^. witsTxL . rdmrsTxWitsL
                    patchedEUs =
                        [ (show p, show eu)
                        | (p, (_, eu)) <-
                            Map.toList patchedRdmrs
                        ]
                    preBalanceEst =
                        estimateMinFeeTx
                            pp
                            patchedTx
                            1
                            0
                            0
                appendFile "/tmp/txbuild-debug.log"
                    $ "PRE-BALANCE: patched-EUs="
                        <> show patchedEUs
                        <> " estimateMinFee="
                        <> show preBalanceEst
                        <> "\n"
                case balanceTx
                    pp
                    inputUtxos
                    changeAddr
                    patchedTx of
                    Left err ->
                        pure $
                            Left $
                                BalanceFailed err
                    Right balanced -> do
                        let finalFee =
                                balanced
                                    ^. bodyTxL
                                        . feeTxBodyL
                            newMax =
                                max maxFee finalFee
                            Redeemers balRdmrs =
                                balanced
                                    ^. witsTxL
                                        . rdmrsTxWitsL
                            balEUs =
                                [ (show p, show eu)
                                | (p, (_, eu)) <-
                                    Map.toList
                                        balRdmrs
                                ]
                            postBalanceEst =
                                estimateMinFeeTx
                                    pp
                                    balanced
                                    1
                                    0
                                    0
                        appendFile "/tmp/txbuild-debug.log"
                            $ "POST-BALANCE:"
                                <> " finalFee="
                                <> show finalFee
                                <> " prevFee="
                                <> show prevFee
                                <> " balanced-EUs="
                                <> show balEUs
                                <> " postEstimate="
                                <> show postBalanceEst
                                <> "\n"
                        if finalFee == prevFee
                            then
                                if newMax > finalFee
                                    then
                                        -- Fee converged
                                        -- but below max.
                                        -- Re-iterate
                                        -- once with max
                                        -- so Peek sees
                                        -- the right fee.
                                        step
                                            seenFees
                                            newMax
                                            ( bumpFee
                                                balanced
                                                newMax
                                            )
                                    else
                                        -- Truly
                                        -- converged.
                                        case failedChecks
                                            (tsChecks st)
                                            balanced of
                                            [] ->
                                                pure $
                                                    Right
                                                        balanced
                                            errs ->
                                                pure $
                                                    Left $
                                                        ChecksFailed
                                                            errs
                            else
                                if Set.member
                                    finalFee
                                    seenFees
                                    then do
                                        -- Oscillation!
                                        let lo =
                                                min
                                                    finalFee
                                                    prevFee
                                            hi =
                                                max
                                                    finalFee
                                                    prevFee
                                        bisect
                                            st
                                            evalResult
                                            balanced
                                            lo
                                            hi
                                    else
                                        step
                                            ( Set.insert
                                                finalFee
                                                seenFees
                                            )
                                            newMax
                                            balanced

    -- \| Binary search for the smallest fee where
    -- eval passes. lo fails eval, hi passes.
    bisect st evalResult templateTx lo hi
        | unCoin hi <= unCoin lo + 1 =
            -- hi is the smallest valid fee.
            -- Build final tx with hi.
            finalize st evalResult templateTx hi
        | otherwise = do
            let mid =
                    Coin $
                        unCoin lo
                            + (unCoin hi - unCoin lo)
                                `div` 2
            -- Re-interpret with mid fee
            let midTx =
                    bumpFee templateTx mid
                midWithIns = addExtras midTx
            (st', _, _) <-
                interpretWithM
                    (runInterpretIO interpret)
                    midWithIns
                    prog
            let tx' =
                    assembleTxWith extraIns pp st'
                        & bodyTxL . feeTxBodyL .~ mid
            -- Balance to get change output
            case balanceTx
                pp
                inputUtxos
                changeAddr
                tx' of
                Left _ ->
                    -- Can't balance at mid, go hi
                    bisect
                        st
                        evalResult
                        templateTx
                        mid
                        hi
                Right balanced -> do
                    let midBal =
                            bumpFee balanced mid
                    -- Evaluate with change output
                    evalResult' <-
                        evaluateTx midBal
                    let failures' =
                            [ e
                            | (_, Left e) <-
                                Map.toList
                                    evalResult'
                            ]
                    if null failures'
                        then
                            -- mid works, try lower
                            bisect
                                st'
                                evalResult'
                                midBal
                                lo
                                mid
                        else
                            -- mid fails, try higher
                            bisect
                                st
                                evalResult
                                templateTx
                                mid
                                hi

    -- \| Finalize with a specific fee.
    --
    -- Re-interpret + assemble so Peek sees the
    -- chosen fee, patch ExUnits, then balance.
    -- If balanceTx lowered the fee (it computes
    -- min_fee), bump it back and shrink the change
    -- output to compensate.
    finalize _st evalResult _templateTx fee = do
        -- Re-interpret with the chosen fee
        let feeTx =
                mkBasicTx mkBasicTxBody
                    & bodyTxL . feeTxBodyL .~ fee
            feeTxWithIns = addExtras feeTx
        (st', _, _) <-
            interpretWithM
                (runInterpretIO interpret)
                feeTxWithIns
                prog
        let tx' =
                assembleTxWith extraIns pp st'
                    & bodyTxL . feeTxBodyL .~ fee
            patched =
                patchExUnits tx' evalResult
        case balanceTx
            pp
            inputUtxos
            changeAddr
            patched of
            Left err ->
                pure $ Left $ BalanceFailed err
            Right balanced -> do
                let balFee =
                        balanced
                            ^. bodyTxL . feeTxBodyL
                    final =
                        if balFee == fee
                            then balanced
                            else bumpFee balanced fee
                case failedChecks
                    (tsChecks st')
                    final of
                    [] -> pure $ Right final
                    errs ->
                        pure $
                            Left $
                                ChecksFailed errs

    -- \| Patch ExUnits from eval result.
    patchExUnits tx evalResult =
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
            newRdmrs = Redeemers patched
            integrity =
                if Map.null patched
                    then SNothing
                    else
                        hashScriptIntegrity
                            ( Set.singleton
                                ( getLanguageView
                                    pp
                                    PlutusV3
                                )
                            )
                            newRdmrs
                            (TxDats mempty)
         in tx
                & witsTxL . rdmrsTxWitsL
                    .~ newRdmrs
                & bodyTxL
                    . scriptIntegrityHashTxBodyL
                    .~ integrity

{- | Bump fee from what balanceTx set to a higher
target, reducing the last output (change) to
compensate.

When bisection finds a fee > min_fee,
balanceTx sets fee = min_fee and puts the
excess into the change output. This function
moves the difference back: increase fee,
decrease change.

Pre-condition: outputs must be non-empty (the
last one is the change output added by
balanceTx).
-}
bumpFee :: Tx ConwayEra -> Coin -> Tx ConwayEra
bumpFee tx targetFee =
    let currentFee = tx ^. bodyTxL . feeTxBodyL
        diff = unCoin targetFee - unCoin currentFee
        outs =
            foldr
                (:)
                []
                (tx ^. bodyTxL . outputsTxBodyL)
     in case reverse outs of
            [] ->
                error
                    "bumpFee: no outputs to \
                    \adjust"
            (changeOut : rest) ->
                let Coin changeVal =
                        changeOut ^. coinTxOutL
                    adjusted =
                        changeOut
                            & coinTxOutL
                                .~ Coin
                                    (changeVal - diff)
                    newOuts =
                        StrictSeq.fromList
                            (reverse (adjusted : rest))
                 in tx
                        & bodyTxL . feeTxBodyL
                            .~ targetFee
                        & bodyTxL . outputsTxBodyL
                            .~ newOuts

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

withdrawalIndex ::
    RewardAccount ->
    Withdrawals ->
    Word32
withdrawalIndex needle (Withdrawals withdrawals) =
    go 0 (Map.keys withdrawals)
  where
    go _ [] =
        error
            "withdrawalIndex: RewardAccount not in map"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs

-- | Collect spending redeemers from steps.
collectSpendRedeemers ::
    Set TxIn ->
    [(TxIn, SpendWitness)] ->
    [ ( ConwayPlutusPurpose AsIx ConwayEra
      , (Data ConwayEra, ExUnits)
      )
    ]
collectSpendRedeemers allIns spends =
    [ ( ConwaySpending (AsIx ix)
      , (toLedgerData r, ExUnits 0 0)
      )
    | (txIn, ScriptWitness r) <- spends
    , let ix = spendingIndex txIn allIns
    ]

-- | Collect minting redeemers. First per policy.
collectMintRedeemers ::
    [(PolicyID, AssetName, Integer, MintWitness)] ->
    [ ( ConwayPlutusPurpose AsIx ConwayEra
      , (Data ConwayEra, ExUnits)
      )
    ]
collectMintRedeemers mints =
    let
        allPolicies =
            Set.fromList
                [pid | (pid, _, _, _) <- mints]
        policyIdx pid =
            go 0 (Set.toAscList allPolicies)
          where
            go _ [] = error "policyIdx: not found"
            go n (x : xs)
                | x == pid = n
                | otherwise = go (n + 1) xs
        seenData =
            foldl' addP Map.empty mints
        addP acc (pid, _, _, PlutusScriptWitness r)
            | Map.member pid acc = acc
            | otherwise =
                Map.insert pid (toLedgerData r) acc
     in
        [ ( ConwayMinting (AsIx (policyIdx pid))
          , (d, ExUnits 0 0)
          )
        | (pid, d) <- Map.toList seenData
        ]

collectWithdrawalEntries ::
    [(RewardAccount, Coin, WithdrawWitness)] ->
    Map RewardAccount (Coin, Maybe (Data ConwayEra))
collectWithdrawalEntries =
    Map.fromList . fmap toEntry
  where
    toEntry (rewardAccount, amount, witness) =
        ( rewardAccount
        , (amount, withdrawWitnessData witness)
        )

collectWithdrawalRedeemers ::
    Withdrawals ->
    Map RewardAccount (Coin, Maybe (Data ConwayEra)) ->
    [ ( ConwayPlutusPurpose AsIx ConwayEra
      , (Data ConwayEra, ExUnits)
      )
    ]
collectWithdrawalRedeemers withdrawals entries =
    [ ( ConwayRewarding
            (AsIx (withdrawalIndex rewardAccount withdrawals))
      , (redeemer, ExUnits 0 0)
      )
    | (rewardAccount, (_, Just redeemer)) <-
        Map.toList entries
    ]

-- | Accumulate 'MultiAsset' from mint entries.
addMint ::
    MultiAsset ->
    (PolicyID, AssetName, Integer, MintWitness) ->
    MultiAsset
addMint acc (pid, name, qty, _) =
    acc
        <> MultiAsset
            ( Map.singleton
                pid
                (Map.singleton name qty)
            )

withdrawWitnessData ::
    WithdrawWitness ->
    Maybe (Data ConwayEra)
withdrawWitnessData PubKeyWithdraw = Nothing
withdrawWitnessData (ScriptWithdraw redeemer) =
    Just (toLedgerData redeemer)

-- | Convert a 'ToData' value to ledger 'Data'.
toLedgerData :: (ToData a) => a -> Data ConwayEra
toLedgerData x =
    let BuiltinData d = toBuiltinData x
     in Data d

-- | Convert a 'ToData' value to 'PlutusCore.Data'.
toPlcData :: (ToData a) => a -> PLC.Data
toPlcData x =
    let BuiltinData d = toBuiltinData x in d

-- | Wrap 'PlutusCore.Data' as an inline 'Datum'.
mkInlineDatum :: PLC.Data -> Datum ConwayEra
mkInlineDatum d =
    Datum $
        dataToBinaryData
            (Data d :: Data ConwayEra)

failedChecks ::
    [Tx ConwayEra -> Check e] ->
    Tx ConwayEra ->
    [Check e]
failedChecks checks tx =
    [ result
    | check <- checks
    , let result = check tx
    , case result of
        Pass -> False
        _ -> True
    ]

txOutAt ::
    Word32 ->
    StrictSeq.StrictSeq (TxOut ConwayEra) ->
    Maybe (TxOut ConwayEra)
txOutAt ix =
    go (fromIntegral ix :: Int) . foldr (:) []
  where
    go _ [] = Nothing
    go 0 (txOut : _) = Just txOut
    go n (_ : rest) = go (n - 1) rest
