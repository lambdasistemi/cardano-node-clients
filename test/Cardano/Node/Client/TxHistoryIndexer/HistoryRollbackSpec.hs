{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.HistoryRollbackSpec
Description : Slot-aware apply, rollback, and resume for tx-history storage
License     : Apache-2.0

Focused unit tests for Slice 2 of the tx-history indexer. Slice 1
proved tenant/scope isolation and ordered scans for a flat
'appendHistory'; Slice 2 adds the slot-aware, rollback-aware,
resumable surface the shared chain-sync follower drives:

  * 'processHistoryBlock' files a block's entries under a
    @(slot, blockHash)@ rollback point,
  * 'rollbackHistoryTo' drops every entry filed strictly above a
    target slot, and
  * 'getHistoryResumePoints' reports the retained @(slot, blockHash)@
    points so the follower can negotiate a resume intersection.

These mirror the @applyAtSlot@ / @rollbackTo@ / @getResumePoints@
contract the UTxO indexer already exposes, so a single chain-sync
session can drive both stores with separate persisted cursors (the
plan's cursor model 2).
-}
module Cardano.Node.Client.TxHistoryIndexer.HistoryRollbackSpec (spec) where

import Cardano.Node.Client.TxHistoryIndexer.Indexer (
    getHistoryResumePoints,
    processHistoryBlock,
    queryHistory,
    rollbackHistoryTo,
    withInMemoryHistoryIndexer,
    withRocksDBHistoryIndexer,
 )
import Cardano.Node.Client.TxHistoryIndexer.Types (
    HistoryScope (..),
    TenantId (..),
    TxId (..),
    TxRole (..),
    TxSummaryEntry (..),
    TxSummaryKey (..),
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word8)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec =
    describe
        "Cardano.Node.Client.TxHistoryIndexer history rollback/resume"
        $ do
            describe "rollback above a slot" $
                it "drops history entries filed above the rollback slot" $
                    withInMemoryHistoryIndexer $ \ix -> do
                        processHistoryBlock
                            ix
                            (SlotNo 1)
                            (blockHash 1)
                            [entryAt 1 0x11]
                        processHistoryBlock
                            ix
                            (SlotNo 2)
                            (blockHash 2)
                            [entryAt 2 0x22]
                        processHistoryBlock
                            ix
                            (SlotNo 3)
                            (blockHash 3)
                            [entryAt 3 0x33]
                        rollbackHistoryTo ix (SlotNo 1)
                        queryHistory ix tenantA scopeX
                            `shouldReturn` [entryAt 1 0x11]

            describe "resume points" $
                it "reports the newest applied block as the head point" $
                    withInMemoryHistoryIndexer $ \ix -> do
                        processHistoryBlock
                            ix
                            (SlotNo 1)
                            (blockHash 1)
                            [entryAt 1 0x11]
                        processHistoryBlock
                            ix
                            (SlotNo 2)
                            (blockHash 2)
                            [entryAt 2 0x22]
                        pts <- getHistoryResumePoints ix
                        take 1 pts `shouldBe` [(SlotNo 2, blockHash 2)]

            describe "idempotent replay across restart" $
                it "replaying an applied block does not duplicate entries" $
                    withSystemTempDirectory "tx-history-resume" $ \dir -> do
                        withRocksDBHistoryIndexer dir $ \ix ->
                            processHistoryBlock
                                ix
                                (SlotNo 1)
                                (blockHash 1)
                                [entryAt 1 0x11]
                        before <-
                            withRocksDBHistoryIndexer dir $ \ix ->
                                queryHistory ix tenantA scopeX
                        after <-
                            withRocksDBHistoryIndexer dir $ \ix -> do
                                processHistoryBlock
                                    ix
                                    (SlotNo 1)
                                    (blockHash 1)
                                    [entryAt 1 0x11]
                                queryHistory ix tenantA scopeX
                        before `shouldBe` [entryAt 1 0x11]
                        after `shouldBe` before

tenantA :: TenantId
tenantA = TenantId "tenant-a"

scopeX :: HistoryScope
scopeX = HistoryScope "scope-x"

roleInput :: TxRole
roleInput = TxRole "input"

blockHash :: Word8 -> ByteString
blockHash = BS.replicate 32

entryAt :: Word8 -> Word8 -> TxSummaryEntry
entryAt slot tx =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = tenantA
                , tskScope = scopeX
                , tskSlot = SlotNo (fromIntegral slot)
                , tskTxId = TxId (BS.replicate 32 tx)
                , tskRole = roleInput
                }
        , tsePayload = BS.singleton tx
        }
