{-# LANGUAGE RankNTypes #-}

-- | Handler interfaces for the generic block indexer.
module Cardano.Node.Client.BlockIndexer.Handler (
    HandlerBlock (..),
    HandlerContext (..),
    IndexerHandler (..),
    composeHandlerFollowing,
    composeHandlerRestoring,
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

-- | Block payload handed to composed indexer handlers.
data HandlerBlock slot meta inv = HandlerBlock
    { hbSlot :: !slot
    , hbMeta :: !meta
    , hbPayload :: !inv
    }

-- | Slot and optional block metadata available while a handler mutates state.
data HandlerContext slot meta = HandlerContext
    { hcSlot :: !slot
    , hcMeta :: !(Maybe meta)
    }

{- | Transaction-level block-indexer handler.

The @inv@ type is both the incoming per-block payload and the rollback inverse
payload. A composed handler list runs all handlers in one transaction and
combines their inverses with 'mconcat' before the engine stores one rollback
point.
-}
data IndexerHandler cols inv = IndexerHandler
    { handlerRestore ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op ()
    , handlerFollow ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op inv
    , handlerRollback ::
        forall cf op slot meta.
        (Typeable slot, Typeable meta) =>
        HandlerContext slot meta ->
        inv ->
        Transaction IO cf cols op ()
    }

-- | Compose handlers into a restoration continuation.
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

-- | Compose handlers into a following continuation.
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

-- | Apply stored rollback inverses through each handler in reverse order.
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
