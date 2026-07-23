{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.E2E.PlominScript
Description : Plutus V3 script utilizing Plomin-era builtin (xorByteString) for E2E devnet tests
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.PlominScript (
    -- * Script & Address
    plominScript,
    plominScriptHash,
    plominScriptAddr,

    -- * Transactions
    mkPlominLockTx,
    mkPlominSpendTx,
) where

import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import PlutusCore.DeBruijn (DeBruijn (..), Index (..))
import PlutusCore.Default (DefaultFun (..), DefaultUni (..), Some (..), ValueOf (..))
import PlutusCore.Version (plcVersion100)
import PlutusLedgerApi.V3 (SerialisedScript, serialiseUPLC)
import UntypedPlutusCore.Core.Type (Program (..), Term (..))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.PParams (getLanguageView)
import Cardano.Ledger.Alonzo.Scripts (AlonzoScript (PlutusScript), AsIx (..), ExUnits (..))
import Cardano.Ledger.Alonzo.Tx (ScriptIntegrity (..), hashScriptIntegrity)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..), rdmrsTxWitsL)
import Cardano.Ledger.Api (
    ConwayEra,
    PParams,
    Script,
    ScriptHash,
    collateralInputsTxBodyL,
    feeTxBodyL,
    hashScript,
    inputsTxBodyL,
    mkBasicTx,
    mkBasicTxBody,
    mkBasicTxOut,
    mkBasicTxWits,
    outputsTxBodyL,
    scriptIntegrityHashTxBodyL,
    scriptTxWitsL,
    witsTxL,
 )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (SJust))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..), PlutusScript (ConwayPlutusV3))
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Plutus (Data (..), Language (..), Plutus (..), PlutusBinary (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject)

import Cardano.Node.Client.E2E.Devnet (addKeyWitness, genesisSignKey)
import Cardano.Node.Client.Ledger (ConwayTx)

{- | Minimal Plutus V3 script evaluating the Plomin-era 'xorByteString' builtin on two bytestring constants.
Returns () (unit).
-}
plominScript :: Script ConwayEra
plominScript =
    let val1 = Constant () (Some (ValueOf DefaultUniByteString "hello"))
        val2 = Constant () (Some (ValueOf DefaultUniByteString "world"))
        xorApp = Apply () (Apply () (Builtin () XorByteString) val1) val2
        unitConst = Constant () (Some (ValueOf DefaultUniUnit ()))
        body = Apply () (LamAbs () (DeBruijn (Index 0)) unitConst) xorApp
        term = LamAbs () (DeBruijn (Index 0)) body
        prog = Program () plcVersion100 term

        sBytes :: SerialisedScript
        sBytes = serialiseUPLC prog
        p = Plutus (PlutusBinary sBytes)
     in PlutusScript (ConwayPlutusV3 p)

-- | Script hash of 'plominScript'.
plominScriptHash :: ScriptHash
plominScriptHash = hashScript plominScript

-- | Enterprise script address for 'plominScript'.
plominScriptAddr :: Addr
plominScriptAddr = Addr Testnet (ScriptHashObj plominScriptHash) StakeRefNull

-- | Construct a transaction that locks funds into 'plominScriptAddr'.
mkPlominLockTx :: TxIn -> Coin -> Addr -> ConwayTx
mkPlominLockTx initTxIn initCoin changeAddr =
    let fee = Coin 10_000_000
        lockCoin = Coin 1_000_000_000
        changeCoin = Coin (unCoin initCoin - unCoin fee - unCoin lockCoin)

        txBody =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton initTxIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut plominScriptAddr (inject lockCoin)
                        , mkBasicTxOut changeAddr (inject changeCoin)
                        ]
                & feeTxBodyL .~ fee
     in addKeyWitness genesisSignKey (mkBasicTx txBody)

-- | Construct a transaction that spends funds from 'plominScriptAddr', evaluating 'plominScript'.
mkPlominSpendTx :: TxIn -> TxIn -> PParams ConwayEra -> Coin -> Addr -> ConwayTx
mkPlominSpendTx scriptTxIn collateralTxIn pp scriptCoin changeAddr =
    let fee = Coin 10_000_000
        changeCoin = Coin (unCoin scriptCoin - unCoin fee)
        redeemers = Redeemers $ Map.singleton (ConwaySpending (AsIx 0)) (Data (PLC.I 0), ExUnits 1_000_000 500_000_000)
        langView = getLanguageView pp PlutusV3
        si = ScriptIntegrity redeemers (TxDats @ConwayEra mempty) (Set.singleton langView)
        integrityHash = hashScriptIntegrity @ConwayEra si

        txBody =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton scriptTxIn
                & collateralInputsTxBodyL .~ Set.singleton collateralTxIn
                & outputsTxBodyL .~ StrictSeq.singleton (mkBasicTxOut changeAddr (inject changeCoin))
                & feeTxBodyL .~ fee
                & scriptIntegrityHashTxBodyL .~ SJust integrityHash

        wits =
            mkBasicTxWits
                & scriptTxWitsL .~ Map.singleton plominScriptHash plominScript
                & rdmrsTxWitsL .~ redeemers
     in mkBasicTx txBody & witsTxL .~ wits
