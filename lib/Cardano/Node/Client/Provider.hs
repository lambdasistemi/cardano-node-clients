{-# LANGUAGE RankNTypes #-}

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
    QueryHandle,
    QueryHandleBackend (..),
    mkQueryHandle,
    singleShotQueryHandle,
    singleShotWithAcquired,

    -- * Acquired-session queries
    queryUTxOsH,
    queryUTxOsAtH,
    queryUTxOByTxInH,
    queryProtocolParamsH,
    evaluateTxH,
    posixMsToSlotH,
    posixMsCeilSlotH,

    -- * Result types
    EvaluateTxResult,

    -- * Re-exports
    SlotNo (..),
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

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
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Validity (HorizonError, ValidityChoice)
import Cardano.Slotting.Slot (SlotNo (..))

-- | Per-script evaluation result.
type EvaluateTxResult era =
    Map
        (PlutusPurpose AsIx era)
        ( Either
            (TransactionScriptFailure era)
            ExUnits
        )

{- | Query operations bound to one acquired ledger
snapshot.

The constructor is intentionally not exported.
Provider implementations build handles with
'mkQueryHandle'; consumers only receive a handle
inside 'withAcquired'.
-}
data QueryHandle m = QueryHandle
    { queryUTxOsH ::
        Addr ->
        m [(TxIn, TxOut ConwayEra)]
    -- ^ Look up UTxOs at one address in the
    -- acquired snapshot.
    , queryUTxOsAtH ::
        Set Addr ->
        m (Map Addr [(TxIn, TxOut ConwayEra)])
    -- ^ Look up UTxOs at several addresses in the
    -- acquired snapshot, grouped by address.
    , queryUTxOByTxInH ::
        Set TxIn ->
        m (Map TxIn (TxOut ConwayEra))
    -- ^ Look up UTxOs by 'TxIn' in the acquired
    -- snapshot.
    , queryProtocolParamsH ::
        m (PParams ConwayEra)
    -- ^ Fetch protocol parameters from the acquired
    -- snapshot.
    , evaluateTxH ::
        ConwayTx ->
        m (EvaluateTxResult ConwayEra)
    -- ^ Evaluate script execution units using data
    -- read from the acquired snapshot.
    , posixMsToSlotH ::
        Integer ->
        m SlotNo
    -- ^ Convert POSIX milliseconds to a floor slot
    -- using the acquired snapshot's interpreter.
    , posixMsCeilSlotH ::
        Integer ->
        m SlotNo
    -- ^ Convert POSIX milliseconds to a ceiling slot
    -- using the acquired snapshot's interpreter.
    }

{- | Named operations used by provider backends to
construct an opaque 'QueryHandle'.
-}
data QueryHandleBackend m = QueryHandleBackend
    { backendQueryUTxOs ::
        Addr ->
        m [(TxIn, TxOut ConwayEra)]
    , backendQueryUTxOsAt ::
        Set Addr ->
        m (Map Addr [(TxIn, TxOut ConwayEra)])
    , backendQueryUTxOByTxIn ::
        Set TxIn ->
        m (Map TxIn (TxOut ConwayEra))
    , backendQueryProtocolParams ::
        m (PParams ConwayEra)
    , backendEvaluateTx ::
        ConwayTx ->
        m (EvaluateTxResult ConwayEra)
    , backendPosixMsToSlot ::
        Integer ->
        m SlotNo
    , backendPosixMsCeilSlot ::
        Integer ->
        m SlotNo
    }

-- | Build a 'QueryHandle' for a provider backend.
mkQueryHandle :: QueryHandleBackend m -> QueryHandle m
mkQueryHandle backend =
    QueryHandle
        { queryUTxOsH = backendQueryUTxOs backend
        , queryUTxOsAtH = backendQueryUTxOsAt backend
        , queryUTxOByTxInH = backendQueryUTxOByTxIn backend
        , queryProtocolParamsH = backendQueryProtocolParams backend
        , evaluateTxH = backendEvaluateTx backend
        , posixMsToSlotH = backendPosixMsToSlot backend
        , posixMsCeilSlotH = backendPosixMsCeilSlot backend
        }

{- | Build a 'QueryHandle' that delegates to a
provider's one-shot fields.

This is useful for test providers and non-LSQ
backends where a true acquired session is not
available.
-}
singleShotQueryHandle ::
    (Applicative m) =>
    Provider m ->
    QueryHandle m
singleShotQueryHandle provider =
    mkQueryHandle
        QueryHandleBackend
            { backendQueryUTxOs = queryUTxOs provider
            , backendQueryUTxOsAt = queryAddresses
            , backendQueryUTxOByTxIn = queryUTxOByTxIn provider
            , backendQueryProtocolParams = queryProtocolParams provider
            , backendEvaluateTx = evaluateTx provider
            , backendPosixMsToSlot = posixMsToSlot provider
            , backendPosixMsCeilSlot = posixMsCeilSlot provider
            }
  where
    queryAddresses addrs =
        Map.fromList
            <$> traverse queryAddress (Set.toList addrs)
    queryAddress addr =
        (,) addr
            <$> queryUTxOs provider addr

-- | Run a callback with a one-shot-backed handle.
singleShotWithAcquired ::
    (Applicative m) =>
    Provider m ->
    (QueryHandle m -> m a) ->
    m a
singleShotWithAcquired provider callback =
    callback (singleShotQueryHandle provider)

{- | Interface for querying the blockchain.
All era-specific types are fixed to 'ConwayEra'.
-}
data Provider m = Provider
    { withAcquired ::
        forall a.
        (QueryHandle m -> m a) ->
        m a
    -- ^ Run several queries against one acquired
    -- ledger snapshot when the backend supports it.
    , queryUTxOs ::
        Addr ->
        m [(TxIn, TxOut ConwayEra)]
    -- ^ Look up UTxOs at an address
    , queryUTxOByTxIn ::
        Set TxIn ->
        m (Map TxIn (TxOut ConwayEra))
    -- ^ Look up UTxOs by their 'TxIn' at the
    --     current chain tip. Returns only those
    --     inputs still unspent; missing entries
    --     are spent or rolled past.
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
    -- ^ Convert POSIX time (milliseconds) to 'SlotNo'
    --     using the node's hard-fork interpreter (floor).
    --     Use for upper validity bounds (@entirely_before@).
    , posixMsCeilSlot ::
        Integer ->
        m SlotNo
    -- ^ Convert POSIX time (milliseconds) to 'SlotNo',
    --     rounding up (ceiling).
    --     Use for lower validity bounds (@entirely_after@).
    , queryUpperBoundSlot ::
        ValidityChoice ->
        m (Either HorizonError SlotNo)
    -- ^ Compute an @invalid-hereafter@ slot under a
    --     'ValidityChoice'. Queries the chain tip and the
    --     hard-fork interpreter and delegates to
    --     'Cardano.Node.Client.Validity.selectUpperBound'.
    }
