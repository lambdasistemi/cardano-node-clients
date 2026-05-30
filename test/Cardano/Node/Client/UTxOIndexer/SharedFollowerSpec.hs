{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.SharedFollowerSpec
Description : Same-session history attachment + shared resume contract
License     : Apache-2.0

Focused unit tests for the Slice 2 follower seam. The downstream
requirement is one chain-sync session that drives both the UTxO
indexer and the tx-history indexer. This suite pins the shape that
makes that possible without abusing @csHandlers@ (which is
@[UtxoOp]@-only) or @csBlockTracer@ (a tracer, not a data path):

  * 'ChainSyncConfig' carries an explicit, optional history
    attachment ('csHistory') that bundles a treasury-neutral
    'DecodeTx' plug point with a 'HistoryIndexer' to write into, and

  * 'sharedResumePoint' chooses the same-session resume intersection
    by taking the oldest safe point across the attached stores'
    persisted cursors — the plan's cursor model 2. Resuming any newer
    than the lagging store's head would skip blocks that store never
    saw; an empty store forces a cold boot.
-}
module Cardano.Node.Client.UTxOIndexer.SharedFollowerSpec (spec) where

import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.TxHistoryIndexer.BlockExtract (
    DecodeTx,
    mkBlockTx,
 )
import Cardano.Node.Client.TxHistoryIndexer.Indexer (
    queryHistory,
    withInMemoryHistoryIndexer,
 )
import Cardano.Node.Client.TxHistoryIndexer.Types (
    HistoryScope (..),
    TenantId (..),
    TxDirection (..),
    TxId (..),
    TxRole (..),
    TxSummary,
    TxSummaryEntry (..),
    TxSummaryKey (..),
    entryToSummary,
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    HistoryAttachment,
    InterestSet (..),
    historyAttachment,
    processSharedFollowerBlock,
    sharedResumePoint,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    liveUtxoHandler,
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Slotting.Slot qualified as Slot
import Control.Tracer (nullTracer)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust, isNothing)
import Data.Word (Word8)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldReturn,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer shared-session history" $ do
        describe "shared-session resume point" $ do
            it "is the oldest safe point across UTxO and history stores" $
                -- UTxO applied through slot 10; history lags at slot 7.
                -- The only point both stores can safely resume from is
                -- the lagging store's head (slot 7).
                sharedResumePoint utxoPoints historyPoints
                    `shouldBe` Just (SlotNo 7, h 7)

            it "cold-boots (Nothing) when either store has no points" $ do
                sharedResumePoint [] historyPoints `shouldBe` Nothing
                sharedResumePoint utxoPoints [] `shouldBe` Nothing

        describe "history attachment seam on the follower config" $ do
            it "defaults to no history attachment" $
                csHistory (baseCfg Nothing) `shouldSatisfy` isNothing

            it "carries a DecodeTx plug point and a history indexer" $
                withInMemoryHistoryIndexer $ \ix -> do
                    let att = historyAttachment decodeNothing ix
                    csHistory (baseCfg (Just att)) `shouldSatisfy` isJust

        describe "shared block-processing path drives both stores"
            $ it
                "one block populates history via a slot-aware DecodeTx \
                \while preserving UTxO behavior"
            $ withInMemoryIndexer
            $ \utxoIdx ->
                withInMemoryHistoryIndexer $ \histIdx -> do
                    let att = historyAttachment decodeAtSlot histIdx
                    state0 <- newFollowerState utxoIdx True
                    -- Single pass over one block: the UTxO ops and
                    -- the history [BlockTx] extracted from the SAME
                    -- block are applied through one shared seam — no
                    -- second chain-sync runner, no csHandlers/tracer
                    -- abuse. The processed slot is supplied here, not
                    -- baked into a fixture, so a decoder that hardcodes
                    -- or guesses its slot cannot satisfy the assertion.
                    _ <-
                        processSharedFollowerBlock
                            utxoIdx
                            att
                            state0
                            2 -- security param k
                            True -- within stability window
                            processedSlot
                            (BlockHash (BS.replicate 32 0xBB))
                            [UtxoCreate txInA addrA outA]
                            [mkBlockTx (BS.replicate 32 0xAB)]
                    -- UTxO behavior preserved: the created output is
                    -- visible at its address.
                    snapshotAt utxoIdx addrA
                        `shouldReturn` [(txInA, outA)]
                    -- History populated through the decoder plug
                    -- point on the same pass, keyed at the block slot
                    -- the decoder received.
                    queryHistory histIdx tenantA scopeX
                        `shouldReturn` [decodedEntryAt expectedHistorySlot]

-- | A treasury-neutral decoder that never emits history entries.
decodeNothing :: DecodeTx
decodeNothing _ _ = Nothing

{- | A non-trivial, still treasury-neutral decoder: every transaction
in the block yields one history entry keyed at the /block slot the
follower passes in/. The decoder is defined in the test, not the
library, so no scope/redeemer semantics leak into the plug point; and
because it builds its entry from the received slot it pins the
slot-aware contract — a decoder that hardcoded a slot would file the
entry under the wrong key.
-}
decodeAtSlot :: DecodeTx
decodeAtSlot slot _ = Just [decodedSummaryAt slot]

{- | The single entry 'decodeAtSlot' emits for the integration block,
keyed at the slot it received.
-}
decodedEntryAt :: Slot.SlotNo -> TxSummaryEntry
decodedEntryAt slot =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = tenantA
                , tskScope = scopeX
                , tskSlot = slot
                , tskTxId = TxId (BS.replicate 32 0xAB)
                , tskRole = TxRole "output"
                }
        , tsePayload = "history-payload"
        , tseDirection = TxDirection "outbound"
        }

decodedSummaryAt :: Slot.SlotNo -> TxSummary
decodedSummaryAt = entryToSummary . decodedEntryAt

-- | The block slot driven through the shared follower pass.
processedSlot :: SlotNo
processedSlot = SlotNo 12

-- | The history-store slot the decoder must receive for 'processedSlot'.
expectedHistorySlot :: Slot.SlotNo
expectedHistorySlot = Slot.SlotNo 12

tenantA :: TenantId
tenantA = TenantId "tenant-a"

scopeX :: HistoryScope
scopeX = HistoryScope "scope-x"

txInA :: TxIn
txInA = TxIn (BS.replicate 32 0x01) 0

addrA :: Address
addrA = Address (BS.replicate 29 0xAA)

outA :: TxOut
outA = TxOut "tag-A"

utxoPoints, historyPoints :: [(SlotNo, BlockHash)]
utxoPoints =
    [ (SlotNo 10, h 10)
    , (SlotNo 9, h 9)
    , (SlotNo 8, h 8)
    , (SlotNo 7, h 7)
    ]
historyPoints =
    [ (SlotNo 7, h 7)
    , (SlotNo 6, h 6)
    ]

h :: Word8 -> BlockHash
h = BlockHash . BS.replicate 32

{- | A 'ChainSyncConfig' parameterised only on the optional history
attachment; every other field is a fixed, side-effect-free default.
-}
baseCfg :: Maybe HistoryAttachment -> ChainSyncConfig
baseCfg mHist =
    ChainSyncConfig
        { csRelaySocket = "/tmp/does-not-exist.sock"
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
        , csHistory = mHist
        }
