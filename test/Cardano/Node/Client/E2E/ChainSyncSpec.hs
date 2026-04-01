{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.E2E.ChainSyncSpec
Description : E2E test for ChainSync phase transition
License     : Apache-2.0

Verifies that a chain follower connected to a real
devnet node goes through the restoration→following
phase transition. Uses a no-op backend (ignores block
contents) with a small stability window so the
transition triggers quickly once the node catches up.
-}
module Cardano.Node.Client.E2E.ChainSyncSpec (spec) where

import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import ChainFollower.Backend (
    Following (..),
    Init (..),
    Restoring (..),
 )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types (
    RollbackPoint (..),
 )
import ChainFollower.Runner (
    Phase (..),
    processBlock,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race)
import Control.Concurrent.STM (
    TMVar,
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTMVar,
 )
import Control.Lens (prism')
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (
    IORef,
    modifyIORef',
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.Type.Equality ((:~:) (..))
import Database.KV.Database (
    KV,
    mkColumns,
 )
import Database.KV.InMemory (mkInMemoryDatabase)
import Database.KV.Transaction (
    Codecs (..),
    DSum ((:=>)),
    GCompare (..),
    GEq (..),
    GOrdering (..),
    Transaction,
    fromPairList,
    runTransactionUnguarded,
 )
import Ouroboros.Network.Block (
    Point (..),
    SlotNo (..),
    blockSlot,
 )
import Ouroboros.Network.Point (WithOrigin (..))
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )
import Text.Read (readMaybe)

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
 )
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )

-- * No-op backend

-- | Trivial inverse type — no state to undo.
data NoOpInv = NoOpInv
    deriving stock (Show, Eq, Read)

-- | In-memory transaction type.
type T =
    Transaction
        IO
        Int
        RollbackCols
        (Int, ByteString, Maybe ByteString)

-- | No-op restoring continuation.
noOpRestoring :: Restoring IO T Fetched NoOpInv ()
noOpRestoring =
    Restoring
        { restore = \_ -> pure noOpRestoring
        , toFollowing = pure noOpFollowing
        }

-- | No-op following continuation.
noOpFollowing :: Following IO T Fetched NoOpInv ()
noOpFollowing =
    Following
        { follow = \_ ->
            pure (NoOpInv, Nothing, noOpFollowing)
        , toRestoring = pure noOpRestoring
        , applyInverse = \_ -> pure ()
        }

-- | No-op backend initialization.
noOpInit :: Init IO T Fetched NoOpInv ()
noOpInit = Init{start = pure noOpRestoring}

-- * Rollback column

-- | Single-column GADT for rollback storage.
data RollbackCols c where
    RollbackCol ::
        RollbackCols
            (KV SlotNo (RollbackPoint NoOpInv ()))

instance GEq RollbackCols where
    geq RollbackCol RollbackCol = Just Refl

instance GCompare RollbackCols where
    gcompare RollbackCol RollbackCol = GEQ

rollbackCodecs :: [DSum RollbackCols Codecs]
rollbackCodecs =
    [ RollbackCol
        :=> Codecs
            ( prism'
                (BS8.pack . show . unSlotNo)
                (fmap SlotNo . readMaybe . BS8.unpack)
            )
            ( prism'
                (BS8.pack . show)
                (readMaybe . BS8.unpack)
            )
    ]

-- | Transaction runner type.
type RunTx =
    forall a. T a -> IO a

-- | Create an in-memory rollback database.
withRollbackDB :: (RunTx -> IO a) -> IO a
withRollbackDB action = do
    db <-
        mkInMemoryDatabase $
            mkColumns [0 ..] (fromPairList rollbackCodecs)
    action $ runTransactionUnguarded db

-- * Follower wiring

type TestPhase =
    Phase
        IO
        Int
        RollbackCols
        (Int, ByteString, Maybe ByteString)
        Fetched
        NoOpInv
        ()

{- | Build an Intersector that starts from origin
and feeds blocks through the Runner.
-}
mkTestIntersector ::
    RunTx ->
    IORef TestPhase ->
    IORef Int ->
    TMVar () ->
    Intersector HeaderPoint SlotNo Fetched
mkTestIntersector runTx phaseRef blockCountRef transitionVar =
    Intersector
        { intersectFound = \_ ->
            pure $
                mkTestFollower
                    runTx
                    phaseRef
                    blockCountRef
                    transitionVar
        , intersectNotFound =
            pure
                ( mkTestIntersector
                    runTx
                    phaseRef
                    blockCountRef
                    transitionVar
                , []
                )
        }

{- | Build a Follower that calls processBlock on
each received block and signals when the phase
transitions to InFollowing.
-}
mkTestFollower ::
    RunTx ->
    IORef TestPhase ->
    IORef Int ->
    TMVar () ->
    Follower HeaderPoint SlotNo Fetched
mkTestFollower runTx phaseRef blockCountRef transitionVar =
    let self =
            mkTestFollower
                runTx
                phaseRef
                blockCountRef
                transitionVar
     in Follower
            { rollForward = \fetched tipSlot -> do
                phase <- readIORef phaseRef
                let slot = blockSlot (fetchedBlock fetched)
                    atTip =
                        tipSlot > 0 && slot >= tipSlot
                phase' <-
                    processBlock
                        atTip
                        runTx
                        RollbackCol
                        2
                        slot
                        fetched
                        phase
                writeIORef phaseRef phase'
                modifyIORef' blockCountRef (+ 1)
                case (phase, phase') of
                    (InRestoration _, InFollowing _ _) ->
                        atomically $
                            putTMVar transitionVar ()
                    _ -> pure ()
                pure self
            , rollBackward = \_ ->
                pure $ Progress self
            }

-- * Test

spec :: Spec
spec =
    describe "ChainSync phase transition" $ do
        it "transitions from InRestoration to InFollowing on a real devnet" $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \sock _startMs ->
                withRollbackDB $ \runTx -> do
                    -- Setup rollback column
                    runTx $
                        Rollbacks.armageddonSetup
                            RollbackCol
                            (SlotNo 0)
                            Nothing

                    -- Initialize no-op backend
                    restoring <- start noOpInit
                    phaseRef <- newIORef (InRestoration restoring)
                    blockCountRef <- newIORef (0 :: Int)
                    transitionVar <- newEmptyTMVarIO

                    -- Build intersector starting from origin
                    let intersector =
                            mkTestIntersector
                                runTx
                                phaseRef
                                blockCountRef
                                transitionVar

                    -- Run ChainSync in background
                    syncThread <-
                        async $
                            runChainSyncN2C
                                (EpochSlots 42)
                                devnetMagic
                                sock
                                ( mkChainSyncN2C
                                    nullTracer
                                    nullTracer
                                    intersector
                                    [Point Origin]
                                )

                    -- Wait for transition or timeout (60s)
                    result <-
                        race
                            (threadDelay 60_000_000)
                            ( atomically $
                                readTMVar transitionVar
                            )

                    cancel syncThread

                    -- Verify transition happened
                    result `shouldSatisfy` isRight'

                    blockCount <- readIORef blockCountRef
                    blockCount `shouldSatisfy` (> 0)

                    finalPhase <- readIORef phaseRef
                    isFollowing' finalPhase `shouldBe` True
  where
    isRight' (Right _) = True
    isRight' _ = False
    isFollowing' (InFollowing _ _) = True
    isFollowing' _ = False
