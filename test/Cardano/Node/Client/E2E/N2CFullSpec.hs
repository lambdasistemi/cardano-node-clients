{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.N2CFullSpec
Description : E2E smoke test for runNodeClientFull (#95)
License     : Apache-2.0

Verifies that the combined N2C connection helper added in
@#95@ negotiates ChainSync (num 5) + LSQ (num 7) + LTxS
(num 6) on a single mux session against a real devnet
node. Success criterion: from one 'runNodeClientFull'
call we observe both a ChainSync roll-forward and a
successful LSQ protocol-parameters query within a
bounded window.

LTxS is wired in but not exercised by this smoke test —
the handshake at @NodeToClientV_20@ admits the
mini-protocol either with the others or not at all, so
the LTxS channel becoming usable falls out of the
combined-mux working at all. End-to-end LTxS coverage
arrives with the tx-generator's own E2E suite.
-}
module Cardano.Node.Client.E2E.N2CFullSpec (spec) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
 )
import Cardano.Node.Client.N2C.ChainSync (
    Fetched,
    HeaderPoint,
    mkChainSyncN2C,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClientFull,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider (Provider (..))
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    async,
    cancel,
    race,
 )
import Control.Concurrent.STM (
    TMVar,
    atomically,
    newEmptyTMVarIO,
    readTMVar,
    tryPutTMVar,
 )
import Control.Tracer (nullTracer)
import Lens.Micro ((^.))
import Ouroboros.Network.Block (Point (..), SlotNo)
import Ouroboros.Network.Point (WithOrigin (Origin))
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "runNodeClientFull (#95)" $
        it "carries ChainSync + LSQ on a single mux session" $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \sock _startMs -> do
                blockSeenVar <- newEmptyTMVarIO
                lsq <- newLSQChannel 16
                ltxs <- newLTxSChannel 16
                let chainSyncApp =
                        mkChainSyncN2C
                            nullTracer
                            nullTracer
                            (firstBlockIntersector blockSeenVar)
                            [Point Origin]

                conn <-
                    async $
                        runNodeClientFull
                            devnetMagic
                            (EpochSlots 42)
                            sock
                            chainSyncApp
                            lsq
                            ltxs

                -- Allow the mux to negotiate before the LSQ
                -- session opens.
                threadDelay 3_000_000

                -- LSQ: a successful protocol-params query
                -- proves the LSQ mini-protocol is wired
                -- correctly.
                let provider = mkN2CProvider lsq
                pp <- queryProtocolParams provider
                (pp ^. ppMaxTxSizeL) `shouldSatisfy` (> 0)

                -- ChainSync: at least one roll-forward
                -- proves the ChainSync mini-protocol is
                -- wired correctly. 60 s budget — devnet
                -- typically produces the first block well
                -- under that.
                result <-
                    race
                        (threadDelay 60_000_000)
                        (atomically (readTMVar blockSeenVar))

                cancel conn
                result `shouldSatisfy` isRight'
  where
    isRight' :: Either a b -> Bool
    isRight' (Right _) = True
    isRight' _ = False

{- | Trivial Intersector that, on intersection, returns a
follower which signals the supplied 'TMVar' on the first
roll-forward and ignores subsequent blocks.
-}
firstBlockIntersector ::
    TMVar () ->
    Intersector HeaderPoint SlotNo Fetched
firstBlockIntersector seen =
    Intersector
        { intersectFound = \_ ->
            pure (firstBlockFollower seen)
        , intersectNotFound =
            pure (firstBlockIntersector seen, [])
        }

firstBlockFollower ::
    TMVar () ->
    Follower HeaderPoint SlotNo Fetched
firstBlockFollower seen =
    let self = firstBlockFollower seen
     in Follower
            { rollForward = \_fetched _tipSlot -> do
                _ <- atomically (tryPutTMVar seen ())
                pure self
            , rollBackward = \_ ->
                pure (Progress self)
            }
