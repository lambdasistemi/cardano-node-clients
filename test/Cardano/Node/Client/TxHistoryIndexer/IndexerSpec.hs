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
    appendSummaries,
    getByTxId,
    processHistoryBlock,
    queryHistory,
    withInMemoryHistoryIndexer,
    withRocksDBHistoryIndexer,
 )
import Cardano.Node.Client.TxHistoryIndexer.Types (
    HistoryScope (..),
    TenantId (..),
    TxDirection (..),
    TxId (..),
    TxRole (..),
    TxSummary (..),
    TxSummaryEntry (..),
    TxSummaryInput (..),
    TxSummaryKey (..),
    TxSummaryOutput (..),
    TxSummaryValue (..),
    summaryToEntry,
    summaryValueFromBytes,
    summaryValueOf,
    summaryValueToBytes,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Word (Word8)
import Database.RocksDB (Config (..), withDBCF)
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

        describe "tx-id lookup" $ do
            it "returns a detailed summary scoped by tenant and txid" $
                withInMemoryHistoryIndexer $ \indexer -> do
                    let summary =
                            mkSummary tenantA scopeX 7 0x44 roleOutput
                        otherTenant =
                            mkSummary tenantB scopeX 7 0x44 roleInput
                    appendSummaries indexer [otherTenant, summary]
                    getByTxId
                        indexer
                        tenantA
                        (TxId (BS.replicate 32 0x44))
                        `shouldReturn` Just summary
                    getByTxId
                        indexer
                        tenantB
                        (TxId (BS.replicate 32 0x55))
                        `shouldReturn` Nothing

            it "keeps scope scans compatible with detailed summaries" $
                withInMemoryHistoryIndexer $ \indexer -> do
                    let summary =
                            mkSummary tenantA scopeX 8 0x45 roleOutput
                    appendSummaries indexer [summary]
                    queryHistory indexer tenantA scopeX
                        `shouldReturn` [summaryToEntry summary]

            it "stamps block-processed summaries with the block hash" $
                withInMemoryHistoryIndexer $ \indexer -> do
                    let summary =
                            (mkSummary tenantA scopeX 9 0x47 roleOutput)
                                { txsBlockHash = Nothing
                                }
                        expected = summary{txsBlockHash = Just "block-9"}
                    processHistoryBlock indexer (SlotNo 9) "block-9" [summary]
                    getByTxId
                        indexer
                        tenantA
                        (TxId (BS.replicate 32 0x47))
                        `shouldReturn` Just expected

            it
                "round-trips detailed summaries through the RocksDB \
                \codec and getByTxId"
                $ withSystemTempDirectory "tx-history-rocks-detail"
                $ \dir ->
                    withRocksDBHistoryIndexer dir $ \indexer -> do
                        let summary =
                                mkSummary tenantA scopeX 9 0x46 roleOutput
                        appendSummaries indexer [summary]
                        getByTxId
                            indexer
                            tenantA
                            (TxId (BS.replicate 32 0x46))
                            `shouldReturn` Just summary

            it "round-trips direction through the value codec" $ do
                let value =
                        (summaryValueOf (mkSummary tenantA scopeX 10 0x48 roleInput))
                            { tsvDirection = TxDirection "inbound"
                            }
                summaryValueFromBytes (summaryValueToBytes value)
                    `shouldBe` Just value

        describe "RocksDB compatibility" $ do
            it "opens a store created with the previous two column families" $
                withSystemTempDirectory "tx-history-rocks-legacy-schema" $
                    \dir -> do
                        withDBCF
                            dir
                            def{createIfMissing = True}
                            [ ("tx-history.entries", def)
                            , ("tx-history.blocks", def)
                            ]
                            $ \_ -> pure ()
                        withRocksDBHistoryIndexer dir $ \indexer ->
                            queryHistory indexer tenantA scopeX
                                `shouldReturn` []

            it "decodes pre-detail payload bytes as empty-detail values" $ do
                let legacyPayload = "\SOHlegacy-payload"
                summaryValueFromBytes legacyPayload
                    `shouldBe` Just
                        TxSummaryValue
                            { tsvPayload = legacyPayload
                            , tsvInputs = []
                            , tsvOutputs = []
                            , tsvRedeemer = Nothing
                            , tsvFee = Nothing
                            , tsvRequiredSigners = []
                            , tsvBlockHash = Nothing
                            , tsvDirection = TxDirection "outbound"
                            }

            it "decodes pre-direction v1 detail bytes as outbound" $ do
                let payloadBytes = "v1-payload"
                    v1Bytes =
                        "\NULtx-summary-v1"
                            <> lenPrefixed16Test payloadBytes
                            <> "\NUL\NUL" -- inputs
                            <> "\NUL\NUL" -- outputs
                            <> "\NUL" -- redeemer
                            <> "\NUL" -- fee
                            <> "\NUL\NUL" -- required signers
                            <> "\NUL" -- block hash
                summaryValueFromBytes v1Bytes
                    `shouldBe` Just
                        TxSummaryValue
                            { tsvPayload = payloadBytes
                            , tsvInputs = []
                            , tsvOutputs = []
                            , tsvRedeemer = Nothing
                            , tsvFee = Nothing
                            , tsvRequiredSigners = []
                            , tsvBlockHash = Nothing
                            , tsvDirection = TxDirection "outbound"
                            }

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
        , tseDirection = TxDirection "outbound"
        }

payload :: Word8 -> ByteString
payload = BS.singleton

lenPrefixed16Test :: ByteString -> ByteString
lenPrefixed16Test bs =
    let n = BS.length bs
     in BS.pack [fromIntegral (n `div` 256), fromIntegral n] <> bs

mkSummary ::
    TenantId ->
    HistoryScope ->
    Word8 ->
    Word8 ->
    TxRole ->
    TxSummary
mkSummary tenant scope slot tx role =
    TxSummary
        { txsKey =
            TxSummaryKey
                { tskTenant = tenant
                , tskScope = scope
                , tskSlot = SlotNo (fromIntegral slot)
                , tskTxId = TxId (BS.replicate 32 tx)
                , tskRole = role
                }
        , txsPayload = payload tx
        , txsInputs =
            [ TxSummaryInput
                { tsiTxIn = "input#0"
                , tsiScope = Just scope
                , tsiValue = "42 lovelace"
                }
            ]
        , txsOutputs =
            [ TxSummaryOutput
                { tsoAddress = "addr1..."
                , tsoValue = "40 lovelace"
                , tsoDatum = Just "datum-summary"
                }
            ]
        , txsRedeemer = Just "redeemer-summary"
        , txsFee = Just 2
        , txsRequiredSigners = ["signer-a", "signer-b"]
        , txsBlockHash = Just "block-hash"
        , txsDirection = TxDirection "outbound"
        }
