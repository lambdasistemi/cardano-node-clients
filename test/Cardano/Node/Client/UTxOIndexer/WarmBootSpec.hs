{- |
Module      : Cardano.Node.Client.UTxOIndexer.WarmBootSpec
Description : Chain-sync resume from a store with retained rollback points
License     : Apache-2.0

A store that already applied blocks resumes chain-sync from its own
rollback points (a warm boot). The follower hands its chain-sync runner
the intersector that negotiates those points; this spec plays the
runner. The intersector must be usable as a value: it is forced before
any answer from a node, so it may not hide a failure in a field. A
genuine not-found must still refuse to replay from origin over the
populated store.
-}
module Cardano.Node.Client.UTxOIndexer.WarmBootSpec (spec) where

import Cardano.Node.Client.N2C.ChainSync (Fetched, HeaderPoint)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    InterestSet (..),
    withChainSyncFollowerUsing,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    liveUtxoHandler,
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import ChainFollower (Intersector (..))
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (foldM_, void)
import Control.Tracer (nullTracer)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Word (Word64)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraHash (..))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec :: Spec
spec =
    describe "chain-sync resume from a store with retained rollback points" $ do
        it "hands the runner an intersector it can force, offering the store's own points" $
            withInMemoryIndexer $ \idx -> do
                seedBlocks idx [3, 5, 8]
                stored <- getResumePoints idx
                (forced, offered) <- runWarmBoot idx (void . evaluate)
                forced `shouldBe` Right ()
                length stored `shouldBe` 3
                offered `shouldBe` map (uncurry headerPoint) stored

        it "still refuses to replay from origin when no retained point intersects" $
            withInMemoryIndexer $ \idx -> do
                seedBlocks idx [3, 5, 8]
                (notFound, _) <-
                    runWarmBoot idx (void . intersectNotFound)
                case notFound of
                    Left why
                        | "found no intersection" `isInfixOf` why -> pure ()
                    other ->
                        expectationFailure
                            ("a not-found on a populated store answered " <> show other)

{- | Run the follower with a runner that applies the action to the
intersector it receives, and return the action's outcome with the
points the runner was offered.
-}
runWarmBoot ::
    IndexerHandle ->
    (Intersector HeaderPoint Network.SlotNo Fetched -> IO ()) ->
    IO (Either String (), [HeaderPoint])
runWarmBoot idx act = do
    outcome <- newEmptyMVar
    let runner _ _ _ _ _ isect points = do
            r <- try @SomeException (act isect)
            putMVar outcome (either (Left . displayException) Right r, points)
            pure (Right ())
    withChainSyncFollowerUsing runner nullN2CTracer cfg idx $ \_ ->
        takeMVar outcome

-- | Apply one block per slot, each creating one output, inside the window.
seedBlocks :: IndexerHandle -> [Word64] -> IO ()
seedBlocks idx slots = do
    st0 <- newFollowerState idx True
    foldM_ apply st0 slots
  where
    apply st s =
        fst
            <$> processFollowerBlock
                idx
                st
                100
                True
                (SlotNo s)
                (hashAt s)
                [UtxoCreate (txInAt s) (Address (BS.replicate 29 0xAA)) (TxOut "\x80")]

hashAt :: Word64 -> BlockHash
hashAt s = BlockHash (BS.replicate 32 (fromIntegral s))

txInAt :: Word64 -> TxIn
txInAt s = TxIn (BS.replicate 32 (fromIntegral s)) 0

headerPoint :: SlotNo -> BlockHash -> HeaderPoint
headerPoint (SlotNo slot) (BlockHash bytes) =
    Network.Point
        ( Network.Point.At
            (Network.Point.Block (Network.SlotNo slot) (OneEraHash (SBS.toShort bytes)))
        )

cfg :: ChainSyncConfig
cfg =
    ChainSyncConfig
        { csRelaySocket = "/nonexistent/warm-boot-spec.sock"
        , csNetworkMagic = NetworkMagic 42
        , csByronEpochSlots = 86_400
        , csStartPoint = Nothing
        , csReadyThresholdSlots = 5
        , csSecurityParamK = 432
        , csReconnectPolicy = defaultReconnectPolicy
        , csProbeConfig = defaultProbeConfig
        , csInterestSet = IndexAll
        , csHandlers = liveUtxoHandler IndexAll :| []
        , csBlockTracer = nullTracer
        , csTipTracer = nullTracer
        , csHistory = Nothing
        }
