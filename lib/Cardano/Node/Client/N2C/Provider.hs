{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.N2C.Provider
Description : N2C-backed Provider via LocalStateQuery
License     : Apache-2.0

Production implementation of the 'Provider'
interface. Queries a local Cardano node via the
N2C LocalStateQuery mini-protocol using an
'LSQChannel' (see "Cardano.Node.Client.N2C.Connection").

Protocol parameters and UTxOs are retrieved with
Conway-era queries. An era mismatch (node not yet
in Conway) results in a runtime error.
-}
module Cardano.Node.Client.N2C.Provider (
    -- * Construction
    mkN2CProvider,
) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

import Control.Monad.Trans.Except (runExcept)
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Plutus.Evaluate (
    evalTxExUnits,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, bodyTxL)
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Slotting.EpochInfo (hoistEpochInfo)
import Cardano.Slotting.Time (
    RelativeTime (..),
    toRelativeTime,
 )

import Ouroboros.Consensus.Cardano.Block (
    pattern QueryIfCurrentConway,
 )
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query (
    QueryHardFork (GetInterpreter),
    pattern QueryHardFork,
 )
import Ouroboros.Consensus.HardFork.History.EpochInfo (
    interpreterToEpochInfo,
 )
import Ouroboros.Consensus.HardFork.History.Qry (
    interpretQuery,
    wallclockToSlot,
 )
import Ouroboros.Consensus.Ledger.Query (
    Query (BlockQuery, GetSystemStart),
 )
import Ouroboros.Consensus.Shelley.Ledger.Query (
    pattern GetCurrentPParams,
    pattern GetUTxOByAddress,
    pattern GetUTxOByTxIn,
 )

import Cardano.Node.Client.N2C.LocalStateQuery (
    queryAcquiredLSQ,
    withAcquiredLSQ,
 )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Provider (
    EvaluateTxResult,
    Provider (..),
    QueryHandle,
    QueryHandleBackend (..),
    SlotNo,
    evaluateTxH,
    mkQueryHandle,
    posixMsCeilSlotH,
    posixMsToSlotH,
    queryProtocolParamsH,
    queryUTxOByTxInH,
    queryUTxOsH,
 )
import Cardano.Node.Client.Types (Block)

{- | Create a 'Provider IO' backed by the N2C
LocalStateQuery protocol.
-}
mkN2CProvider ::
    -- | LocalStateQuery channel to the Cardano node
    LSQChannel ->
    Provider IO
mkN2CProvider ch =
    Provider
        { withAcquired = withAcquiredN2C
        , queryProtocolParams =
            withAcquiredN2C queryProtocolParamsH
        , queryUTxOs = \addr ->
            withAcquiredN2C $ \handle ->
                queryUTxOsH handle addr
        , queryUTxOByTxIn = \txins ->
            withAcquiredN2C $ \handle ->
                queryUTxOByTxInH handle txins
        , evaluateTx = \tx ->
            withAcquiredN2C $ \handle ->
                evaluateTxH handle tx
        , posixMsToSlot = \ms ->
            withAcquiredN2C $ \handle ->
                posixMsToSlotH handle ms
        , posixMsCeilSlot = \ms ->
            withAcquiredN2C $ \handle ->
                posixMsCeilSlotH handle ms
        }
  where
    withAcquiredN2C ::
        forall a.
        (QueryHandle IO -> IO a) ->
        IO a
    withAcquiredN2C callback =
        withAcquiredLSQ ch $ \acquired ->
            callback $
                mkN2CQueryHandle $
                    queryAcquiredLSQ acquired

mkN2CQueryHandle ::
    (forall result. Query Block result -> IO result) ->
    QueryHandle IO
mkN2CQueryHandle runQuery =
    mkQueryHandle
        QueryHandleBackend
            { backendQueryUTxOs = queryOneAddress
            , backendQueryUTxOsAt = queryUTxOsAtN2C runQuery
            , backendQueryUTxOByTxIn = queryUTxOByTxInN2C runQuery
            , backendQueryProtocolParams = queryProtocolParamsN2C runQuery
            , backendEvaluateTx = evaluateTxN2C runQuery
            , backendPosixMsToSlot = posixMsToSlotN2C runQuery
            , backendPosixMsCeilSlot = posixMsCeilSlotN2C runQuery
            }
  where
    queryOneAddress addr =
        Map.findWithDefault [] addr
            <$> queryUTxOsAtN2C
                runQuery
                (Set.singleton addr)

queryProtocolParamsN2C ::
    (forall result. Query Block result -> IO result) ->
    IO (PParams ConwayEra)
queryProtocolParamsN2C runQuery = do
    result <-
        runQuery $
            BlockQuery $
                QueryIfCurrentConway
                    GetCurrentPParams
    case result of
        Right pp -> pure pp
        Left _mismatch ->
            error
                "queryProtocolParams: era \
                \mismatch — node not in Conway"

queryUTxOsAtN2C ::
    (forall result. Query Block result -> IO result) ->
    Set.Set Addr ->
    IO (Map.Map Addr [(TxIn, TxOut ConwayEra)])
queryUTxOsAtN2C runQuery addrs = do
    result <-
        runQuery $
            BlockQuery $
                QueryIfCurrentConway $
                    GetUTxOByAddress addrs
    case result of
        Right utxo ->
            pure $
                groupUTxOByAddress addrs $
                    unUTxO utxo
        Left _mismatch ->
            error
                "queryUTxOsAtH: era mismatch \
                \— node not in Conway"

groupUTxOByAddress ::
    Set.Set Addr ->
    Map.Map TxIn (TxOut ConwayEra) ->
    Map.Map Addr [(TxIn, TxOut ConwayEra)]
groupUTxOByAddress addrs utxo =
    Map.unionWith (++) grouped emptyRequested
  where
    emptyRequested =
        Map.fromSet (const []) addrs
    grouped =
        foldl' addEntry Map.empty $
            Map.toAscList utxo
    addEntry acc (txIn, txOut)
        | Set.member addr addrs =
            Map.insertWith
                (flip (++))
                addr
                [(txIn, txOut)]
                acc
        | otherwise =
            acc
      where
        addr =
            txOut ^. addrTxOutL

queryUTxOByTxInN2C ::
    (forall result. Query Block result -> IO result) ->
    Set.Set TxIn ->
    IO (Map.Map TxIn (TxOut ConwayEra))
queryUTxOByTxInN2C runQuery txins = do
    result <-
        runQuery $
            BlockQuery $
                QueryIfCurrentConway $
                    GetUTxOByTxIn txins
    case result of
        Right utxo -> pure $ unUTxO utxo
        Left _mismatch ->
            error
                "queryUTxOByTxIn: era \
                \mismatch — node not in \
                \Conway"

evaluateTxN2C ::
    (forall result. Query Block result -> IO result) ->
    ConwayTx ->
    IO (EvaluateTxResult ConwayEra)
evaluateTxN2C runQuery tx = do
    let body = tx ^. bodyTxL
        allInputs =
            Set.unions
                [ body ^. inputsTxBodyL
                , body
                    ^. collateralInputsTxBodyL
                , body
                    ^. referenceInputsTxBodyL
                ]
    -- Resolve UTxOs for all inputs
    utxoResult <-
        runQuery $
            BlockQuery $
                QueryIfCurrentConway $
                    GetUTxOByTxIn allInputs
    utxo <- case utxoResult of
        Right u -> pure u
        Left _mismatch ->
            error
                "evaluateTx: era mismatch \
                \— node not in Conway"
    -- Protocol parameters
    ppResult <-
        runQuery $
            BlockQuery $
                QueryIfCurrentConway
                    GetCurrentPParams
    pp <- case ppResult of
        Right p -> pure p
        Left _mismatch ->
            error
                "evaluateTx: era mismatch \
                \— node not in Conway"
    -- System start
    systemStart <-
        runQuery GetSystemStart
    -- Hard-fork interpreter → EpochInfo
    interpreter <-
        runQuery $
            BlockQuery $
                QueryHardFork GetInterpreter
    let epochInfo =
            hoistEpochInfo
                ( first (T.pack . show)
                    . runExcept
                )
                $ interpreterToEpochInfo
                    interpreter
    pure $
        evalTxExUnits
            pp
            tx
            utxo
            epochInfo
            systemStart

posixMsToSlotN2C ::
    (forall result. Query Block result -> IO result) ->
    Integer ->
    IO SlotNo
posixMsToSlotN2C runQuery ms = do
    (slot, _, _) <-
        queryWallclockToSlot runQuery ms
    pure slot

posixMsCeilSlotN2C ::
    (forall result. Query Block result -> IO result) ->
    Integer ->
    IO SlotNo
posixMsCeilSlotN2C runQuery ms = do
    (slot, timeInSlot, _slotLen) <-
        queryWallclockToSlot runQuery ms
    -- If the time falls exactly on a slot
    -- boundary, floor == ceil. Otherwise
    -- advance to the next slot.
    pure $
        if timeInSlot == 0
            then slot
            else slot + 1

{- | Query SystemStart and HardFork interpreter,
then convert POSIX milliseconds to a slot via
'wallclockToSlot'. Returns the slot, time elapsed
within that slot, and the slot length.
-}
queryWallclockToSlot ::
    (forall result. Query Block result -> IO result) ->
    Integer ->
    IO (SlotNo, NominalDiffTime, NominalDiffTime)
queryWallclockToSlot runQuery ms = do
    systemStart <-
        runQuery GetSystemStart
    interpreter <-
        runQuery $
            BlockQuery $
                QueryHardFork GetInterpreter
    let utcTime =
            posixSecondsToUTCTime $
                fromIntegral ms / 1000
        relTime =
            toRelativeTime
                systemStart
                utcTime
        clamped =
            RelativeTime $
                max 0 $
                    getRelativeTime relTime
    case interpretQuery
        interpreter
        (wallclockToSlot clamped) of
        Right r -> pure r
        Left err ->
            error $
                "posixMsToSlot: "
                    <> show err
