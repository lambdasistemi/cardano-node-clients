{- |
Module      : Cardano.Node.Client.BlockIndexer.HandlerSpec
Description : Multi-handler block-indexer regression tests
License     : Apache-2.0

Exercises the generic block-indexer handler composition path with
the concrete UTxO handler and a second trivial handler. The test
uses the real in-memory @kv-transactions@ database and rollback log
so roll-forward composition and rollback fanout are proven through
the same public API used by downstream indexers.
-}
module Cardano.Node.Client.BlockIndexer.HandlerSpec (spec) where

import Cardano.Node.Client.BlockIndexer.Engine qualified as Engine
import Cardano.Node.Client.BlockIndexer.Handler (
    HandlerContext (..),
    IndexerHandler (..),
 )
import Cardano.Node.Client.BlockIndexer.Handler qualified as Handler
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    InterestSet (..),
    UtxoOp (..),
    liveUtxoHandler,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Tracer (nullTracer)
import Data.ByteString qualified as BS
import Data.Dependent.Map (DMap)
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Typeable (Typeable, cast)
import Database.KV.Database (Codecs, mkColumns)
import Database.KV.InMemory (mkInMemoryDatabase)
import Database.KV.Transaction (
    DSum ((:=>)),
    RunTransaction (..),
    Transaction,
    fromList,
    insert,
    newRunTransaction,
    query,
 )
import Ouroboros.Network.Magic (NetworkMagic (..))
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.BlockIndexer.Handler" $ do
        it
            "composes live UTxO follow and deterministic rollback fanout"
            $ assertFollowRollbackFanout
                (liveUtxoHandler IndexAll :| [recordingHandler liveTxIn])

        it
            "uses ChainSyncConfig csHandlers for handler fanout"
            $ do
                let cfg =
                        testChainSyncConfig
                            { csHandlers =
                                liveUtxoHandler IndexAll
                                    :| [recordingHandler liveTxIn]
                            }
                assertFollowRollbackFanout (csHandlers cfg)

assertFollowRollbackFanout ::
    NonEmpty (IndexerHandler Cols [UtxoOp]) ->
    IO ()
assertFollowRollbackFanout handlers = do
    db <-
        mkInMemoryDatabase
            (mkColumns [0 :: Int ..] indexerTestCodecs)
    RunTransaction{runTransaction} <- newRunTransaction db

    let context =
            HandlerContext
                { hcSlot = followedSlot
                , hcMeta = Just followedHash
                }

    result <-
        runTransaction $
            Engine.applyWithRollbackLog
                RollbackCol
                followedSlot
                followedHash
                ( Handler.followHandlers
                    handlers
                    context
                    [UtxoCreate liveTxIn liveAddress liveTxOut]
                )
    case result of
        Engine.ApplyLogApplied -> pure ()
        Engine.ApplyLogAlreadyApplied ->
            expectationFailure "block was not freshly applied"
        Engine.ApplyLogConflict _existing _attempted ->
            expectationFailure "unexpected rollback-log conflict"

    applied <- runTransaction queryAppliedState
    applied
        `shouldBe` ( Just liveAddress
                   , Just (followedSlot, followedHash)
                   , Nothing
                   , Just
                        RollbackPoint
                            { rpInverses =
                                [[UtxoSpend liveTxIn]]
                            , rpMeta = Just followedHash
                            }
                   )

    deleted <-
        runTransaction $
            Engine.rollbackLogAfter
                RollbackCol
                (rollbackEntry handlers)
                rollbackTarget
    deleted `shouldBe` 1

    rolledBack <- runTransaction queryRolledBackState
    rolledBack
        `shouldBe` ( Nothing
                   , Just (followedSlot, followedHash)
                   , Nothing
                   , Just (followedSlot, followedHash)
                   , Nothing
                   , Nothing
                   )

indexerTestCodecs :: DMap Cols Codecs
indexerTestCodecs =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        ]

recordingHandler :: TxIn -> IndexerHandler Cols [UtxoOp]
recordingHandler trackedTxIn =
    IndexerHandler
        { handlerRestore = \_context _ops -> pure ()
        , handlerFollow = \context _ops -> do
            let (slot, bh) = expectSlotHash context
            mAddress <- query TxInCol trackedTxIn
            case mAddress of
                Just _ ->
                    insert ObservationCol followSawLive (slot, bh)
                Nothing ->
                    insert ObservationCol followSawMissing (slot, bh)
            pure mempty
        , handlerRollback = \context _ops -> do
            let (slot, bh) = expectSlotHash context
            mAddress <- query TxInCol trackedTxIn
            case mAddress of
                Just _ ->
                    insert ObservationCol rollbackSawLive (slot, bh)
                Nothing ->
                    insert ObservationCol rollbackSawMissing (slot, bh)
        }

rollbackEntry ::
    NonEmpty (IndexerHandler Cols [UtxoOp]) ->
    SlotNo ->
    Maybe BlockHash ->
    [[UtxoOp]] ->
    Transaction IO cf Cols op ()
rollbackEntry handlers slot (Just bh) inverseBatches =
    traverse_
        ( Handler.rollbackHandlers
            handlers
            HandlerContext
                { hcSlot = slot
                , hcMeta = Just bh
                }
        )
        inverseBatches
rollbackEntry _handlers _slot Nothing [] = pure ()
rollbackEntry _handlers _slot Nothing (_ : _) =
    error "rollbackEntry: inverse batches require block metadata"

queryAppliedState ::
    Transaction
        IO
        cf
        Cols
        op
        ( Maybe Address
        , Maybe (SlotNo, BlockHash)
        , Maybe (SlotNo, BlockHash)
        , Maybe (RollbackPoint [UtxoOp] BlockHash)
        )
queryAppliedState = do
    mLiveAddress <- query TxInCol liveTxIn
    followLive <- query ObservationCol followSawLive
    followMissing <- query ObservationCol followSawMissing
    rollbackPoint <- query RollbackCol followedSlot
    pure (mLiveAddress, followLive, followMissing, rollbackPoint)

queryRolledBackState ::
    Transaction
        IO
        cf
        Cols
        op
        ( Maybe Address
        , Maybe (SlotNo, BlockHash)
        , Maybe (SlotNo, BlockHash)
        , Maybe (SlotNo, BlockHash)
        , Maybe (SlotNo, BlockHash)
        , Maybe (RollbackPoint [UtxoOp] BlockHash)
        )
queryRolledBackState = do
    mLiveAddress <- query TxInCol liveTxIn
    followLive <- query ObservationCol followSawLive
    followMissing <- query ObservationCol followSawMissing
    rollbackLive <- query ObservationCol rollbackSawLive
    rollbackMissing <- query ObservationCol rollbackSawMissing
    rollbackPoint <- query RollbackCol followedSlot
    pure
        ( mLiveAddress
        , followLive
        , followMissing
        , rollbackLive
        , rollbackMissing
        , rollbackPoint
        )

expectSlotHash ::
    (Typeable slot, Typeable meta) =>
    HandlerContext slot meta ->
    (SlotNo, BlockHash)
expectSlotHash HandlerContext{hcSlot, hcMeta} =
    case (cast hcSlot, hcMeta >>= cast) of
        (Just slot, Just bh) -> (slot, bh)
        _ -> error "recordingHandler: expected SlotNo/BlockHash context"

followedSlot :: SlotNo
followedSlot = SlotNo 42

rollbackTarget :: SlotNo
rollbackTarget = SlotNo 41

followedHash :: BlockHash
followedHash = BlockHash (BS.replicate 32 0xA1)

liveAddress :: Address
liveAddress = Address (BS.replicate 29 0xAA)

liveTxIn :: TxIn
liveTxIn = TxIn (BS.replicate 32 0x11) 0

liveTxOut :: TxOut
liveTxOut = TxOut "live-output"

followSawLive :: TxIn
followSawLive = markerTxIn 0xF1

followSawMissing :: TxIn
followSawMissing = markerTxIn 0xF2

rollbackSawLive :: TxIn
rollbackSawLive = markerTxIn 0xF3

rollbackSawMissing :: TxIn
rollbackSawMissing = markerTxIn 0xF4

markerTxIn :: Word -> TxIn
markerTxIn tag = TxIn (BS.replicate 32 (fromIntegral tag)) 0

testChainSyncConfig :: ChainSyncConfig
testChainSyncConfig =
    ChainSyncConfig
        { csRelaySocket = "unused.sock"
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
