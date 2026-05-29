{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.IndexerSpec
Description : Tenant/scope isolation and ordered scans for tx-history storage
License     : Apache-2.0

Focused unit tests for Slice 1 of the tx-history indexer storage
foundation. Proves that the in-memory indexer:

  * scopes every query by @(tenant, scope)@ so one tenant's
    appended entries never leak into another tenant's query
    (tenant isolation) and one scope's entries never leak into
    another scope's query (scope isolation),
  * keeps strict byte-prefix tenants/scopes (@"a"@ vs @"ab"@,
    @"x"@ vs @"xy"@) from bleeding into one another, forcing the
    ordered key codec to length-prefix the variable-length parts,
    and
  * returns the entries of a single @(tenant, scope)@ query
    ordered by @(slot, txid, role)@ regardless of append order.
-}
module Cardano.Node.Client.TxHistoryIndexer.IndexerSpec (spec) where

import Cardano.Node.Client.TxHistoryIndexer.Indexer (
    appendHistory,
    queryHistory,
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
    describe "Cardano.Node.Client.TxHistoryIndexer.Indexer" $ do
        describe "tenant isolation" $
            it "a query returns only entries of its own tenant" $
                withInMemoryHistoryIndexer $
                    \indexer -> do
                        let entA = mkEntry tenantA scopeX 1 0x11 roleInput
                            entB = mkEntry tenantB scopeX 1 0x22 roleInput
                        appendHistory indexer [entA, entB]
                        queryHistory indexer tenantA scopeX
                            `shouldReturn` [entA]

        describe "scope isolation" $
            it "a query returns only entries of its own scope" $
                withInMemoryHistoryIndexer $
                    \indexer -> do
                        let entX = mkEntry tenantA scopeX 1 0x11 roleInput
                            entY = mkEntry tenantA scopeY 1 0x22 roleInput
                        appendHistory indexer [entX, entY]
                        queryHistory indexer tenantA scopeY
                            `shouldReturn` [entY]

        describe "strict-prefix bleed prevention" $ do
            it "tenant \"a\" does not bleed into tenant \"ab\"" $
                withInMemoryHistoryIndexer $
                    \indexer -> do
                        let entShort =
                                mkEntry (TenantId "a") scopeX 1 0x11 roleInput
                            entLong =
                                mkEntry (TenantId "ab") scopeX 1 0x22 roleInput
                        appendHistory indexer [entShort, entLong]
                        queryHistory indexer (TenantId "a") scopeX
                            `shouldReturn` [entShort]
                        queryHistory indexer (TenantId "ab") scopeX
                            `shouldReturn` [entLong]

            it "scope \"x\" does not bleed into scope \"xy\"" $
                withInMemoryHistoryIndexer $
                    \indexer -> do
                        let entShort =
                                mkEntry tenantA (HistoryScope "x") 1 0x11 roleInput
                            entLong =
                                mkEntry tenantA (HistoryScope "xy") 1 0x22 roleInput
                        appendHistory indexer [entShort, entLong]
                        queryHistory indexer tenantA (HistoryScope "x")
                            `shouldReturn` [entShort]
                        queryHistory indexer tenantA (HistoryScope "xy")
                            `shouldReturn` [entLong]

        describe "ordered scope scans"
            $ it
                "returns entries ordered by (slot, txid, role) \
                \regardless of append order"
            $ withInMemoryHistoryIndexer
            $ \indexer -> do
                let early = mkEntry tenantA scopeX 1 0x11 roleInput
                    sameSlotLowTx =
                        mkEntry tenantA scopeX 2 0x01 roleInput
                    sameSlotHighTx =
                        mkEntry tenantA scopeX 2 0x02 roleInput
                    sameTxInput =
                        mkEntry tenantA scopeX 3 0x33 roleInput
                    sameTxOutput =
                        mkEntry tenantA scopeX 3 0x33 roleOutput
                -- Appended deliberately out of order.
                appendHistory
                    indexer
                    [ sameTxOutput
                    , sameSlotHighTx
                    , early
                    , sameTxInput
                    , sameSlotLowTx
                    ]
                queryHistory indexer tenantA scopeX
                    `shouldReturn` [ early
                                   , sameSlotLowTx
                                   , sameSlotHighTx
                                   , sameTxInput
                                   , sameTxOutput
                                   ]

        describe "backend parity (in-memory vs RocksDB)"
            $ it
                "both backends return the same ordered result \
                \for the same appended entries"
            $ do
                let entries =
                        [ mkEntry tenantA scopeX 3 0x33 roleOutput
                        , mkEntry tenantA scopeX 2 0x02 roleInput
                        , mkEntry tenantA scopeX 1 0x11 roleInput
                        , mkEntry tenantA scopeX 3 0x33 roleInput
                        , mkEntry tenantA scopeX 2 0x01 roleInput
                        , mkEntry tenantB scopeY 5 0x55 roleInput
                        ]
                inMem <-
                    withInMemoryHistoryIndexer $ \indexer -> do
                        appendHistory indexer entries
                        queryHistory indexer tenantA scopeX
                onDisk <-
                    withSystemTempDirectory "tx-history-rocks" $
                        \dir ->
                            withRocksDBHistoryIndexer dir $
                                \indexer -> do
                                    appendHistory indexer entries
                                    queryHistory indexer tenantA scopeX
                onDisk `shouldBe` inMem

tenantA, tenantB :: TenantId
tenantA = TenantId "tenant-a"
tenantB = TenantId "tenant-b"

scopeX, scopeY :: HistoryScope
scopeX = HistoryScope "scope-x"
scopeY = HistoryScope "scope-y"

roleInput, roleOutput :: TxRole
roleInput = TxRole "input"
roleOutput = TxRole "output"

mkEntry ::
    TenantId ->
    HistoryScope ->
    Word8 ->
    Word8 ->
    TxRole ->
    TxSummaryEntry
mkEntry tenant scope slot tx role =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = tenant
                , tskScope = scope
                , tskSlot = SlotNo (fromIntegral slot)
                , tskTxId = TxId (BS.replicate 32 tx)
                , tskRole = role
                }
        , tsePayload = payload tx
        }

payload :: Word8 -> ByteString
payload = BS.singleton
