{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.BlockIndexer.Engine
Description : Generic rollback-log engine for block indexers
License     : Apache-2.0

Engine utilities shared by concrete block indexers.

The engine owns concerns that are independent of any indexed
domain: rollback-log watermarks, restoration/following phase
threading, rollback-log pruning counters, and replay/conflict
classification. It deliberately has no dependency on UTxO columns,
UTxO operations, address filters, or the Cardano node transport.

Concrete indexers provide:

* a typed rollback column,
* a transaction runner,
* a chain-follower phase built from one or more handlers, and
* domain callbacks for applying rollback entries.

All mutation supplied to 'applyWithRollbackLog' and
'processEngineBlock' runs in the same @kv-transactions@
transaction as rollback-point storage.
-}
module Cardano.Node.Client.BlockIndexer.Engine (
    -- * Engine state
    EngineState (..),
    EngineTx,
    EnginePhase,

    -- * Replay classification
    ApplyLogResult (..),

    -- * Applying blocks
    applyWithRollbackLog,
    blockWasFollowed,
    processEngineBlock,

    -- * Rollback log
    countRollbackEntries,
    rollbackEngineState,
    rollbackLogAfter,
) where

import ChainFollower.Rollbacks.Column (RollbackCol)
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import ChainFollower.Runner qualified as Runner
import Control.Concurrent.STM (
    STM,
    TVar,
    atomically,
    modifyTVar',
    writeTVar,
 )
import Control.Tracer (nullTracer)
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    lastEntry,
    prevEntry,
 )
import Database.KV.Transaction (
    GCompare,
    KV,
    Transaction,
    delete,
    iterating,
    query,
 )

-- | Transaction type used by block-indexer engine callbacks.
type EngineTx m cf columns op =
    Transaction m cf columns op

-- | Chain-follower runner phase specialized only by caller types.
type EnginePhase cf columns op block inverse meta =
    Runner.Phase
        IO
        cf
        columns
        op
        block
        inverse
        meta

{- | Generic engine state.

The @block@, @inverse@, and @meta@ parameters are supplied by the
concrete indexer. For a multi-handler setup, @inverse@ is typically
the combined inverse payload produced by the registered handlers.
-}
data EngineState cf columns op block inverse meta = EngineState
    { engineRunTransaction ::
        forall a.
        EngineTx IO cf columns op a ->
        IO a
    -- ^ Runner for one atomic @kv-transactions@ transaction.
    , engineCount :: !(TVar Int)
    -- ^ In-memory count of retained rollback-log entries.
    , enginePhase :: !(EnginePhase cf columns op block inverse meta)
    -- ^ Current restoration/following continuation.
    }

-- | Result of an apply attempt against the rollback log watermark.
data ApplyLogResult meta
    = -- | Fresh block was applied and a rollback point was stored.
      ApplyLogApplied
    | -- | Slot is at or below the rollback-log tip and matches known state.
      ApplyLogAlreadyApplied
    | -- | Stored metadata and attempted metadata disagree.
      ApplyLogConflict !meta !meta

{- | Apply a fresh block and store its inverse batch, or
classify an already-applied/pruned/conflicting slot.

The caller supplies the mutation transaction because it is
handler-specific; this function owns the generic rollback-log
watermark and metadata checks.
-}
applyWithRollbackLog ::
    (Ord slot, Eq meta, GCompare columns) =>
    RollbackCol columns slot inverse meta ->
    slot ->
    meta ->
    Transaction IO cf columns op inverse ->
    Transaction IO cf columns op (ApplyLogResult meta)
applyWithRollbackLog rollbackCol slot meta applyFresh = do
    mTipSlot <- Rollbacks.queryTip rollbackCol
    case mTipSlot of
        Nothing -> applyAndStore
        Just tipSlot
            | slot > tipSlot -> applyAndStore
            | otherwise -> do
                existing <- query rollbackCol slot
                case existing of
                    Nothing ->
                        -- Pruned: the slot is below the tip, so it
                        -- has already been applied even though its
                        -- exact metadata is no longer retained.
                        pure ApplyLogAlreadyApplied
                    Just RollbackPoint{rpMeta = Just existingMeta}
                        | existingMeta == meta ->
                            pure ApplyLogAlreadyApplied
                        | otherwise ->
                            pure
                                ( ApplyLogConflict
                                    existingMeta
                                    meta
                                )
                    Just RollbackPoint{rpMeta = Nothing} ->
                        -- Restoration sentinels carry no metadata.
                        -- The slot is at-or-below the rollback-log
                        -- tip, so treat it as already processed.
                        pure ApplyLogAlreadyApplied
  where
    applyAndStore = do
        inverse <- applyFresh
        Rollbacks.storeRollbackPoint
            rollbackCol
            slot
            RollbackPoint
                { rpInverses = [inverse]
                , rpMeta = Just meta
                }
        pure ApplyLogApplied

-- | Count rollback-log entries in a transaction.
countRollbackEntries ::
    (GCompare columns) =>
    RollbackCol columns slot inverse meta ->
    Transaction IO cf columns op Int
countRollbackEntries =
    Rollbacks.countPoints

-- | Process one block through the generic chain-follower runner.
processEngineBlock ::
    (Ord slot, GCompare columns) =>
    RollbackCol columns slot inverse meta ->
    Int ->
    Bool ->
    slot ->
    block ->
    EngineState cf columns op block inverse meta ->
    IO (EngineState cf columns op block inverse meta)
processEngineBlock
    rollbackCol
    securityParam
    withinStabilityWindow
    slot
    block
    engine@EngineState{engineRunTransaction, engineCount, enginePhase} = do
        phase' <-
            Runner.processBlock
                nullTracer
                withinStabilityWindow
                engineRunTransaction
                rollbackCol
                securityParam
                slot
                block
                enginePhase
        atomically $
            syncRunnerCount engineCount enginePhase phase'
        pure engine{enginePhase = phase'}

-- | Whether a block was followed rather than only restored.
blockWasFollowed ::
    EnginePhase cf columns op block inverse meta ->
    Bool ->
    Bool
blockWasFollowed (Runner.InFollowing _ _) _ = True
blockWasFollowed (Runner.InRestoration _) withinStabilityWindow =
    withinStabilityWindow

-- | Roll back persistent state and reduce the in-memory phase count.
rollbackEngineState ::
    (Ord slot, GCompare columns) =>
    RollbackCol columns slot inverse meta ->
    ( slot ->
      Maybe meta ->
      [inverse] ->
      Transaction IO cf columns op ()
    ) ->
    slot ->
    EngineState cf columns op block inverse meta ->
    IO (EngineState cf columns op block inverse meta, Int)
rollbackEngineState
    rollbackCol
    applyEntry
    target
    engine@EngineState{engineRunTransaction, engineCount, enginePhase} = do
        deleted <-
            engineRunTransaction $
                rollbackLogAfter rollbackCol applyEntry target
        let phase' = reducePhaseCount deleted enginePhase
        atomically $
            modifyTVar' engineCount (subtract deleted)
        pure (engine{enginePhase = phase'}, deleted)

{- | Roll back every entry strictly greater than the target key.

Unlike 'ChainFollower.Runner.rollbackTo', this walk does not require
the target key to exist. That preserves the existing cold-boot and
Origin-intersection behavior for the UTxO indexer.
-}
rollbackLogAfter ::
    (Ord slot, GCompare columns) =>
    RollbackCol columns slot inverse meta ->
    ( slot ->
      Maybe meta ->
      [inverse] ->
      Transaction IO cf columns op ()
    ) ->
    slot ->
    Transaction IO cf columns op Int
rollbackLogAfter rollbackCol applyEntry target = do
    entries <-
        iterating rollbackCol $
            collectGreaterThan target
    mapM_ undoEntry entries
    pure (length entries)
  where
    undoEntry (slot, meta, inverses) = do
        applyEntry slot meta inverses
        delete rollbackCol slot

syncRunnerCount ::
    TVar Int ->
    EnginePhase cf columns op block inverse meta ->
    EnginePhase cf columns op block inverse meta ->
    STM ()
syncRunnerCount countVar oldPhase newPhase =
    case newPhase of
        Runner.InRestoration _ ->
            case oldPhase of
                Runner.InRestoration _ ->
                    modifyTVar' countVar (+ 1)
                Runner.InFollowing _ _ ->
                    writeTVar countVar 0
        Runner.InFollowing n _ ->
            writeTVar countVar n

reducePhaseCount ::
    Int ->
    EnginePhase cf columns op block inverse meta ->
    EnginePhase cf columns op block inverse meta
reducePhaseCount deleted = \case
    Runner.InRestoration restoring ->
        Runner.InRestoration restoring
    Runner.InFollowing n following ->
        Runner.InFollowing (max 0 (n - deleted)) following

collectGreaterThan ::
    (Monad m, Ord slot) =>
    slot ->
    Cursor
        m
        (KV slot (RollbackPoint inverse meta))
        [(slot, Maybe meta, [inverse])]
collectGreaterThan target =
    lastEntry >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = slot, entryValue = rp})
        | slot > target =
            let inverses = rpInverses rp
             in prevEntry
                    >>= go ((slot, rpMeta rp, inverses) : acc)
        | otherwise = pure (reverse acc)
