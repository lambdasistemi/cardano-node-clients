{- |
Module      : Cardano.Node.Client.UTxOIndexer.PersistenceSpec
Description : RocksDB-backed indexer survives close + reopen
License     : Apache-2.0

Opens an indexer against a RocksDB database in a tempdir,
applies a few blocks, closes the handle, reopens against
the same path, and verifies that the state — address
index, rollback log, and entry counter — is intact.
-}
module Cardano.Node.Client.UTxOIndexer.PersistenceSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Data.ByteString qualified as BS
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer (RocksDB)" $ do
        it "address index survives close + reopen" $
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x11) 0
                    txout = TxOut "value-bytes-0"
                withRocksDBIndexer dbPath $ \h ->
                    applyAtSlot
                        h
                        (SlotNo 1)
                        testBlockHash
                        [UtxoCreate txin addr txout]
                withRocksDBIndexer dbPath $ \h -> do
                    xs <- snapshotAt h addr
                    xs `shouldBe` [(txin, txout)]

        it "rollback log survives — rollback after reopen undoes prior apply" $
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x11) 0
                withRocksDBIndexer dbPath $ \h ->
                    applyAtSlot
                        h
                        (SlotNo 5)
                        testBlockHash
                        [UtxoCreate txin addr (TxOut "v")]
                withRocksDBIndexer dbPath $ \h -> do
                    rollbackTo h (SlotNo 4)
                    xs <- snapshotAt h addr
                    xs `shouldBe` []

        it "rollback-log counter is rebuilt on reopen" $
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                withRocksDBIndexer dbPath $ \h -> do
                    applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                    applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                    applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                -- Reopen and ask the prune endpoint to keep just
                -- one. It must report 2 deletions — proving the
                -- counter was rebuilt to 3 from the on-disk state,
                -- not reset to 0 on reopen.
                withRocksDBIndexer dbPath $ \h -> do
                    deleted <- pruneRollbacks h 1
                    deleted `shouldBe` 2

        it "spends from a previous session resolve their address" $
            -- Spending a UTxO inserted in a prior session
            -- requires reading the (TxIn → Address) mapping from
            -- on-disk state. If TxInCol weren't persisted, the
            -- post-reopen UtxoSpend would be silently no-op.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x11) 0
                withRocksDBIndexer dbPath $ \h ->
                    applyAtSlot
                        h
                        (SlotNo 1)
                        testBlockHash
                        [UtxoCreate txin addr (TxOut "v")]
                withRocksDBIndexer dbPath $ \h -> do
                    applyAtSlot
                        h
                        (SlotNo 2)
                        testBlockHash
                        [UtxoSpend txin]
                    xs <- snapshotAt h addr
                    xs `shouldBe` []

-- * Test helpers

withTempDB :: (FilePath -> IO a) -> IO a
withTempDB action =
    withSystemTempDirectory "utxo-indexer-rocksdb" $ \tmp ->
        action (tmp </> "db")

testBlockHash :: BlockHash
testBlockHash = BlockHash (BS.replicate 32 0)
