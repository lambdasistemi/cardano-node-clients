{- |
Module      : Cardano.Node.Client.UTxOIndexer.AssetProvenanceSpec
Description : Creation-point provenance across rollback restoration
License     : Apache-2.0

Covers the epic ruling that after a rollback restores a spent output,
@awaitTxIn@ reports the output's original creation slot and block
hash (not the rollback slot), and that rollback-log rows written with
the pre-change op encoding (tags 0\/1) keep decoding and applying with
their old behaviour.

This spec deliberately restricts itself to the pre-change public API
(@applyAtSlot@, @rollbackTo@, @awaitTxIn@, @snapshotAt@, the rollback
column and its op codec) so it executes against the pre-change tree:
the restoration case is the slice's runtime-red witness.
-}
module Cardano.Node.Client.UTxOIndexer.AssetProvenanceSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    encodeOps,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AwaitObservation (..),
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
    slotToBytes,
    txInToBytes,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Data.ByteString qualified as BS
import Data.Default.Class (def)
import Data.Word (Word8)
import Database.KV.Transaction (
    RunTransaction (..),
    insert,
 )
import Database.RocksDB (
    Config (..),
    columnFamilies,
    getCF,
    putCF,
    withDBCF,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer creation provenance" $ do
        describe "awaitTxIn after a rollback restores a spent output" $ do
            it "reports the original creation slot and block hash" $
                withInMemoryIndexer $ \h -> do
                    applyAtSlot
                        h
                        createdSlot
                        createdHash
                        [UtxoCreate txin addr txout]
                    applyAtSlot h (SlotNo 3) spentHash [UtxoSpend txin]
                    rollbackTo h createdSlot
                    obs <- awaitTxIn h txin (Just 1)
                    obs
                        `shouldBe` Just
                            ( mkObservation
                                (SlotNo 1)
                                createdHash
                                txout
                            )

            it "restored output answers snapshotAt with its bytes" $
                withInMemoryIndexer $ \h -> do
                    applyAtSlot
                        h
                        createdSlot
                        createdHash
                        [UtxoCreate txin addr txout]
                    applyAtSlot h (SlotNo 3) spentHash [UtxoSpend txin]
                    rollbackTo h createdSlot
                    xs <- snapshotAt h addr
                    xs `shouldBe` [(txin, txout)]

            it "keeps the original creation point across close + reopen" $
                withSystemTempDirectory "utxo-indexer-provenance" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    withRocksDBIndexer dbPath $ \h -> do
                        applyAtSlot
                            h
                            createdSlot
                            createdHash
                            [UtxoCreate txin addr txout]
                        applyAtSlot h (SlotNo 3) spentHash [UtxoSpend txin]
                        rollbackTo h createdSlot
                    withRocksDBIndexer dbPath $ \h -> do
                        obs <- awaitTxIn h txin (Just 1)
                        obs
                            `shouldBe` Just
                                ( mkObservation
                                    (SlotNo 1)
                                    createdHash
                                    txout
                                )

        describe "pre-change rollback-log rows (tags 0/1)" $ do
            it "still decode and apply with their old behaviour" $
                withInMemoryIndexerRunner $ \h runner -> do
                    -- Hand-write a rollback entry whose inverse batch
                    -- uses the pre-change op encoding (tag 0 create
                    -- inverse): an old store contains exactly this
                    -- shape. Applying it on rollback must behave as
                    -- before: the observation records the rollback
                    -- entry's own slot/hash, because the old encoding
                    -- carries no provenance.
                    runTransaction runner $
                        insert
                            RollbackCol
                            (SlotNo 9)
                            RollbackPoint
                                { rpInverses =
                                    [
                                        [ UtxoCreate
                                            txin
                                            addr
                                            txout
                                        ]
                                    ]
                                , rpMeta = Just rollbackHash
                                }
                    rollbackTo h (SlotNo 5)
                    xs <- snapshotAt h addr
                    xs `shouldBe` [(txin, txout)]
                    obs <- awaitTxIn h txin (Just 1)
                    obs
                        `shouldBe` Just
                            (mkObservation (SlotNo 9) rollbackHash txout)

            it "literal pre-change rows, written raw, decode/apply and are not rewritten" $
                withSystemTempDirectory "utxo-indexer-literal-rows" $ \tmp -> do
                    let dbPath = tmp </> "db"
                        rowKey9 = slotToBytes (SlotNo 9)
                        row9 = literalRollbackValue rollbackHash
                        rowKey10 = slotToBytes (SlotNo 10)
                        row10 = literalCreateValue (BlockHash (BS.replicate 32 0x0A)) txin2 otherAddr (TxOut "second")
                    -- Seed literal pre-change-format rollback rows by
                    -- writing raw bytes through the RocksDB layer,
                    -- independent of the op codec: slot 9 holds a
                    -- non-empty batch of tag-0 create plus tag-1 spend;
                    -- slot 10 holds a tag-0 create of the TxIn that
                    -- slot 9's tag-1 spend removes.
                    withDBCF dbPath def{createIfMissing = True} allFamilies $ \rdb -> do
                        putCF rdb (columnFamilies rdb !! 3) rowKey9 row9
                        putCF rdb (columnFamilies rdb !! 3) rowKey10 row10
                    -- The raw bytes before the indexer session.
                    before9 <- readRawRow dbPath rowKey9
                    before10 <- readRawRow dbPath rowKey10
                    withRocksDBIndexer dbPath $ \h -> do
                        -- Another block applies above the literal rows.
                        applyAtSlot
                            h
                            (SlotNo 12)
                            (BlockHash (BS.replicate 32 0x0C))
                            [UtxoCreate txin3 otherAddr (TxOut "newer")]
                    -- The literal rows survived the other operation
                    -- and a close/reopen byte-for-byte: no rewrite,
                    -- ever.
                    after9 <- readRawRow dbPath rowKey9
                    after10 <- readRawRow dbPath rowKey10
                    after9 `shouldBe` before9
                    after10 `shouldBe` before10
                    withRocksDBIndexer dbPath $ \h -> do
                        -- Applying them rolls back with the old
                        -- behaviour, and the tag-1 spend is real:
                        -- slot 10's create restored its TxIn, slot 9's
                        -- tag-1 spend then removed it — ignoring tag 1
                        -- would leave the output live.
                        rollbackTo h (SlotNo 5)
                        xs <- snapshotAt h addr
                        xs `shouldBe` [(txin, txout)]
                        ys <- snapshotAt h otherAddr
                        ys `shouldBe` []
                        obs <- awaitTxIn h txin (Just 1)
                        obs
                            `shouldBe` Just
                                (mkObservation (SlotNo 9) rollbackHash txout)

            it "encodeOps keeps the pre-change tag-0/1 byte shapes" $ do
                let createOp = UtxoCreate txin addr txout
                    spendOp = UtxoSpend txin
                    encoded = encodeOps [createOp, spendOp]
                    outLen = BS.length "provenance-bytes"
                -- listLen(4) || 0 || txIn(34) || addrLen(4) || addr
                -- \|| txOutLen(4) || txOut || 1 || txIn(34)
                BS.length encoded
                    `shouldBe` 4 + 1 + 34 + 4 + 29 + 4 + outLen + 1 + 34
                BS.take 1 (BS.drop 4 encoded) `shouldBe` BS.pack [0]
                BS.take
                    1
                    (BS.drop (4 + 1 + 34 + 4 + 29 + 4 + outLen) encoded)
                    `shouldBe` BS.pack [1]

-- * Fixtures

txin :: TxIn
txin = TxIn (BS.replicate 32 0x11) 0

txin2 :: TxIn
txin2 = TxIn (BS.replicate 32 0x22) 1

txin3 :: TxIn
txin3 = TxIn (BS.replicate 32 0x33) 2

addr :: Address
addr = Address (BS.replicate 29 0xAA)

otherAddr :: Address
otherAddr = Address (BS.replicate 29 0xBB)

txout :: TxOut
txout = TxOut "provenance-bytes"

createdSlot :: SlotNo
createdSlot = SlotNo 1

createdHash :: BlockHash
createdHash = BlockHash (BS.replicate 32 0x01)

spentHash :: BlockHash
spentHash = BlockHash (BS.replicate 32 0x03)

rollbackHash :: BlockHash
rollbackHash = BlockHash (BS.replicate 32 0x09)

mkObservation :: SlotNo -> BlockHash -> TxOut -> AwaitObservation
mkObservation slot bh out =
    AwaitObservation
        { aoSlot = slot
        , aoBlockHash = bh
        , aoTxOut = out
        }

-- | The full column-family list, in the GADT pairing order.
allFamilies :: [(String, Config)]
allFamilies =
    [ ("utxo-indexer.txin", def)
    , ("utxo-indexer.address", def)
    , ("utxo-indexer.observation", def)
    , ("utxo-indexer.rollback", def)
    , ("utxo-indexer.asset", def)
    , ("utxo-indexer.meta", def)
    ]

-- | Four-byte big-endian word, as the on-disk layouts use.
word32be :: Int -> BS.ByteString
word32be w =
    BS.pack
        [ fromIntegral (w `div` 0x1000000) :: Word8
        , fromIntegral (w `div` 0x10000) :: Word8
        , fromIntegral (w `div` 0x100) :: Word8
        , fromIntegral w :: Word8
        ]

{- | A rollback-entry value in the literal pre-change format:
@hashLen(4) || hash || opCount(4) || ops@ with a non-empty batch of
tag-0 create and tag-1 spend, hand-assembled from the documented
layout — independent of the codec under change.
-}
literalRollbackValue :: BlockHash -> BS.ByteString
literalRollbackValue (BlockHash bh) =
    word32be (fromIntegral (BS.length bh))
        <> bh
        <> word32be 2
        <> tag0OpBytes txin addrBytes outBytes
        <> tag1OpBytes txin2
  where
    addrBytes = BS.replicate 29 0xAA
    outBytes = "provenance-bytes"

-- | A rollback-entry value holding a single literal tag-0 create.
literalCreateValue :: BlockHash -> TxIn -> Address -> TxOut -> BS.ByteString
literalCreateValue (BlockHash bh) t (Address a) (TxOut o) =
    word32be (fromIntegral (BS.length bh))
        <> bh
        <> word32be 1
        <> tag0OpBytes t a o

-- | Literal tag-0 op bytes: @0 || txIn || addrLen || addr || outLen || out@.
tag0OpBytes :: TxIn -> BS.ByteString -> BS.ByteString -> BS.ByteString
tag0OpBytes t a o =
    BS.singleton 0
        <> txInToBytes t
        <> word32be (fromIntegral (BS.length a))
        <> a
        <> word32be (fromIntegral (BS.length o))
        <> o

-- | Literal tag-1 op bytes: @1 || txIn@.
tag1OpBytes :: TxIn -> BS.ByteString
tag1OpBytes t = BS.singleton 1 <> txInToBytes t

-- | Read a rollback row's raw value bytes with a standalone reader.
readRawRow :: FilePath -> BS.ByteString -> IO (Maybe BS.ByteString)
readRawRow dbPath key =
    withDBCF dbPath def{createIfMissing = False} allFamilies $ \rdb ->
        getCF rdb (columnFamilies rdb !! 3) key
