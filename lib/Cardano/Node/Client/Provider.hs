{- |
Module      : Cardano.Node.Client.Provider
Description : Protocol-agnostic query interface
License     : Apache-2.0

Record-of-functions interface for querying the Cardano
blockchain. Protocol-specific implementations provide
constructors (e.g. 'Cardano.Node.Client.N2C.Provider.mkN2CProvider').
-}
module Cardano.Node.Client.Provider (
    -- * Provider interface
    Provider (..),

    -- * Result types
    EvaluateTxResult,

    -- * Re-exports
    SlotNo (..),
) where

import Data.Map.Strict (Map)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Plutus.Evaluate (
    TransactionScriptFailure,
 )
import Cardano.Ledger.Alonzo.Scripts (
    AsIx,
    PlutusPurpose,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Node.Client.Ledger (ConwayTx)

-- | Per-script evaluation result.
type EvaluateTxResult era =
    Map
        (PlutusPurpose AsIx era)
        ( Either
            (TransactionScriptFailure era)
            ExUnits
        )

{- | Interface for querying the blockchain.
All era-specific types are fixed to 'ConwayEra'.
-}
data Provider m = Provider
    { queryUTxOs ::
        Addr ->
        m [(TxIn, TxOut ConwayEra)]
    -- ^ Look up UTxOs at an address
    , queryProtocolParams ::
        m (PParams ConwayEra)
    -- ^ Fetch current protocol parameters
    , evaluateTx ::
        ConwayTx ->
        m (EvaluateTxResult ConwayEra)
    -- ^ Evaluate script execution units
    , posixMsToSlot ::
        Integer ->
        m SlotNo
    {- ^ Convert POSIX time (milliseconds) to 'SlotNo'
    using the node's hard-fork interpreter (floor).
    Use for upper validity bounds (@entirely_before@).
    -}
    , posixMsCeilSlot ::
        Integer ->
        m SlotNo
    {- ^ Convert POSIX time (milliseconds) to 'SlotNo',
    rounding up (ceiling).
    Use for lower validity bounds (@entirely_after@).
    -}
    }
