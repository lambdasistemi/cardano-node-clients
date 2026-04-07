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

import Cardano.Ledger.Alonzo.Plutus.Evaluate (
    evalTxExUnits,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.State (UTxO (..))
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
    queryLSQ,
 )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Provider (Provider (..), SlotNo)

{- | Create a 'Provider IO' backed by the N2C
LocalStateQuery protocol.
-}
mkN2CProvider ::
    -- | LocalStateQuery channel to the Cardano node
    LSQChannel ->
    Provider IO
mkN2CProvider ch =
    Provider
        { queryProtocolParams = do
            result <-
                queryLSQ ch $
                    BlockQuery $
                        QueryIfCurrentConway
                            GetCurrentPParams
            case result of
                Right pp -> pure pp
                Left _mismatch ->
                    error
                        "queryProtocolParams: era \
                        \mismatch — node not in Conway"
        , queryUTxOs = \addr -> do
            result <-
                queryLSQ ch $
                    BlockQuery $
                        QueryIfCurrentConway $
                            GetUTxOByAddress
                                (Set.singleton addr)
            case result of
                Right utxo ->
                    pure $
                        Map.toList $
                            unUTxO utxo
                Left _mismatch ->
                    error
                        "queryUTxOs: era mismatch \
                        \— node not in Conway"
        , evaluateTx = \tx -> do
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
                queryLSQ ch $
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
                queryLSQ ch $
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
                queryLSQ ch GetSystemStart
            -- Hard-fork interpreter → EpochInfo
            interpreter <-
                queryLSQ ch $
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
        , posixMsToSlot = \ms -> do
            (slot, _, _) <-
                queryWallclockToSlot ch ms
            pure slot
        , posixMsCeilSlot = \ms -> do
            (slot, timeInSlot, _slotLen) <-
                queryWallclockToSlot ch ms
            -- If the time falls exactly on a slot
            -- boundary, floor == ceil. Otherwise
            -- advance to the next slot.
            pure $
                if timeInSlot == 0
                    then slot
                    else slot + 1
        }

{- | Query SystemStart and HardFork interpreter,
then convert POSIX milliseconds to a slot via
'wallclockToSlot'. Returns the slot, time elapsed
within that slot, and the slot length.
-}
queryWallclockToSlot ::
    LSQChannel ->
    Integer ->
    IO (SlotNo, NominalDiffTime, NominalDiffTime)
queryWallclockToSlot ch ms = do
    systemStart <-
        queryLSQ ch GetSystemStart
    interpreter <-
        queryLSQ ch $
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
