{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.BlockIndexer.Handler
Description : Generic handler interface for block-indexer engines
License     : Apache-2.0

Transaction-level handler API for block indexers.

This module is deliberately domain-neutral. It knows about
chain-follower restoration/following phases, rollback inverses,
and typed @kv-transactions@ columns, but it does not know about
UTxO-specific columns, address filters, or operation types. A
downstream indexer supplies an 'IndexerHandler' for its own column
GADT and inverse type, then the composition helpers adapt one or
more handlers to the continuation-passing
'ChainFollower.Backend.Restoring' and
'ChainFollower.Backend.Following' interface.

All handler callbacks run in the same block transaction that later
stores the rollback point. This is the boundary that lets multiple
domain handlers share one chain-sync subscription while preserving
atomic block application.
-}
module Cardano.Node.Client.BlockIndexer.Handler (
    -- * Blocks and callback context
    HandlerBlock (..),
    HandlerContext (..),

    -- * Handler callbacks
    IndexerHandler (..),

    -- * Chain-follower adaptation
    composeHandlerFollowing,
    composeHandlerRestoring,

    -- * Direct composition
    followHandlers,
    rollbackHandlers,
)
where

import ChainFollower.Backend (
    Following (..),
    Restoring (..),
 )
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Typeable (Typeable)
import Database.KV.Transaction (Transaction)

{- | Block payload handed to composed indexer handlers.

The @slot@ and @meta@ parameters are owned by the engine
caller. The generic handler layer only carries them through
to callbacks; it does not interpret their concrete types.
-}
data HandlerBlock slot meta inv = HandlerBlock
    { hbSlot :: !slot
    -- ^ Slot or rollback-log key for the block.
    , hbMeta :: !meta
    -- ^ Caller-defined per-block metadata, such as a block hash.
    , hbPayload :: !inv
    -- ^ Domain payload extracted from the block.
    }

{- | Slot and optional block metadata available while a handler mutates state.

Rollback application may be invoked with absent metadata for
restoration sentinel rows. Domain handlers that require concrete
metadata should treat that case as a no-op or a schema error,
depending on their persisted rollback contract.
-}
data HandlerContext slot meta = HandlerContext
    { hcSlot :: !slot
    -- ^ Slot or rollback-log key currently being processed.
    , hcMeta :: !(Maybe meta)
    -- ^ Optional metadata stored with the rollback entry.
    }

{- | Transaction-level block-indexer handler.

The @inv@ type is both the incoming per-block payload and the rollback inverse
payload. A composed handler list runs all handlers in one transaction and
combines their inverses with 'mconcat' before the engine stores one rollback
point.

Handlers should own only domain-specific storage mutation. Slot
watermarks, rollback-log persistence, and phase counters belong in
'Cardano.Node.Client.BlockIndexer.Engine'.
-}
data IndexerHandler cols inv = IndexerHandler
    { handlerRestore ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op ()
    -- ^ Apply a restoration-phase block. No rollback inverse is
    -- returned because restoration checkpoints use sentinel rows.
    , handlerFollow ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op inv
    -- ^ Apply a following-phase block and return its inverse payload.
    , handlerRollback ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op ()
    -- ^ Apply an inverse payload read from the rollback log.
    }

{- | Compose handlers into a restoration continuation.

Handlers run in registration order for each restored block.
-}
composeHandlerRestoring ::
    forall cf cols op slot meta inv.
    (Monoid inv, Typeable slot, Typeable meta) =>
    NonEmpty (IndexerHandler cols inv) ->
    Restoring
        IO
        (Transaction IO cf cols op)
        (HandlerBlock slot meta inv)
        inv
        meta
composeHandlerRestoring handlers = restoring
  where
    restoring =
        Restoring
            { restore = \(HandlerBlock slot meta payload) -> do
                traverse_
                    ( \handler ->
                        handlerRestore
                            handler
                            HandlerContext
                                { hcSlot = slot
                                , hcMeta = Just meta
                                }
                            payload
                    )
                    handlers
                pure restoring
            , toFollowing = pure (composeHandlerFollowing handlers)
            }

{- | Compose handlers into a following continuation.

Handlers run in registration order for each followed block. Their
inverse payloads are combined with 'mconcat' and returned as the
single rollback payload stored by the engine.
-}
composeHandlerFollowing ::
    forall cf cols op slot meta inv.
    (Monoid inv, Typeable slot, Typeable meta) =>
    NonEmpty (IndexerHandler cols inv) ->
    Following
        IO
        (Transaction IO cf cols op)
        (HandlerBlock slot meta inv)
        inv
        meta
composeHandlerFollowing handlers = following
  where
    following =
        Following
            { follow = \(HandlerBlock slot meta payload) -> do
                inverse <-
                    followHandlers
                        handlers
                        HandlerContext
                            { hcSlot = slot
                            , hcMeta = Just meta
                            }
                        payload
                pure (inverse, Just meta, following)
            , toRestoring = pure (composeHandlerRestoring handlers)
            , applyInverse =
                rollbackHandlers
                    handlers
                    HandlerContext
                        { hcSlot = ()
                        , hcMeta = Nothing :: Maybe ()
                        }
            }

-- | Run every handler for a followed block and combine their inverses.
followHandlers ::
    (Monoid inv, Typeable slot, Typeable meta) =>
    NonEmpty (IndexerHandler cols inv) ->
    HandlerContext slot meta ->
    inv ->
    Transaction IO cf cols op inv
followHandlers handlers context payload =
    mconcat
        <$> traverse
            ( \handler ->
                handlerFollow handler context payload
            )
            (NonEmpty.toList handlers)

{- | Apply stored rollback inverses through each handler in reverse order.

Reverse order keeps rollback deterministic for handler sets where a
later handler depends on state written by an earlier one during
follow application.
-}
rollbackHandlers ::
    (Typeable slot, Typeable meta) =>
    NonEmpty (IndexerHandler cols inv) ->
    HandlerContext slot meta ->
    inv ->
    Transaction IO cf cols op ()
rollbackHandlers handlers context inverse =
    traverse_
        ( \handler ->
            handlerRollback handler context inverse
        )
        (reverse (NonEmpty.toList handlers))
