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
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Cardano.Ledger.Address (Addr)
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
    bodyTxL,
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    vldtTxBodyL,
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
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (
    PParams,
    Script,
    hashScript,
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
assembleTx pp st =
    let
        allSpendIns =
            Set.fromList $ map fst (tsSpends st)
        refIns = Set.fromList (tsRefIns st)
        collIns = Set.fromList (tsCollIns st)
        outs = StrictSeq.fromList (tsOuts st)
        mintMA = foldl' addMint mempty (tsMints st)
        -- Build redeemers
        spendRdmrs =
            collectSpendRedeemers
                allSpendIns
                (tsSpends st)
        mintRdmrs = collectMintRedeemers (tsMints st)
        rdmrList = spendRdmrs ++ mintRdmrs
        allRdmrs = Redeemers $ Map.fromList rdmrList
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
                & reqSignerHashesTxBodyL
                    .~ tsSigners st
                & vldtTxBodyL
                    .~ ValidityInterval
                        { invalidBefore = tsValidFrom st
                        , invalidHereafter = tsValidTo st
                        }
                & scriptIntegrityHashTxBodyL
                    .~ integrity
     in
        mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ tsScripts st
            & witsTxL . rdmrsTxWitsL
                .~ allRdmrs

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
    loop (mkBasicTx mkBasicTxBody)
  where
    loop prevTx = do
        -- 1. Interpret with current Tx
        (st, _, converged) <-
            interpretWithM
                (runInterpretIO interpret)
                prevTx
                prog
        let
            tx = assembleTx pp st
        -- 2. Add all input TxIns for eval
        let existingIns =
                tx ^. bodyTxL . inputsTxBodyL
            allIns =
                foldl'
                    ( \s (tin, _) ->
                        Set.insert tin s
                    )
                    existingIns
                    inputUtxos
            txForEval =
                tx
                    & bodyTxL . inputsTxBodyL
                        .~ allIns
        -- 3. Evaluate scripts
        evalResult <- evaluateTx txForEval
        let failures =
                [ (p, e)
                | (p, Left e) <-
                    Map.toList evalResult
                ]
        case failures of
            ((p, e) : _) ->
                pure $ Left $ EvalFailure p e
            [] -> do
                -- 4. Patch ExUnits
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
                    patchedTx =
                        tx
                            & witsTxL . rdmrsTxWitsL
                                .~ newRdmrs
                            & bodyTxL
                                . scriptIntegrityHashTxBodyL
                                .~ integrity
                -- 5. Balance
                case balanceTx
                    pp
                    inputUtxos
                    changeAddr
                    patchedTx of
                    Left err ->
                        pure $
                            Left $
                                BalanceFailed err
                    Right balanced
                        -- 6. Converged?
                        | converged
                            && txBodyEq
                                balanced
                                prevTx ->
                            case failedChecks
                                (tsChecks st)
                                balanced of
                                [] ->
                                    pure $ Right balanced
                                errs ->
                                    pure $
                                        Left $
                                            ChecksFailed errs
                        | otherwise ->
                            loop balanced

-- | Compare Tx bodies for convergence.
txBodyEq ::
    Tx ConwayEra -> Tx ConwayEra -> Bool
txBodyEq a b =
    (a ^. bodyTxL) == (b ^. bodyTxL)

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
