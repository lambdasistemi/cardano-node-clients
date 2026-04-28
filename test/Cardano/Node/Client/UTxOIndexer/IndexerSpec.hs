{- |
Module      : Cardano.Node.Client.UTxOIndexer.IndexerSpec
Description : Apply / snapshot / rollback round-trip
License     : Apache-2.0

Exercises the indexer's apply / snapshot / rollback path
end-to-end through the @kv-transactions@ in-memory
backend: open an indexer, apply 'UtxoCreate' /
'UtxoSpend' ops at multiple slots, roll back to a target
slot, and verify @snapshotAt@ reflects the state at the
target slot.
-}
module Cardano.Node.Client.UTxOIndexer.IndexerSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Data.ByteString qualified as BS
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer.Indexer" $ do
    describe "applyAtSlot + snapshotAt" $ do
        it "snapshots an empty address as an empty list" $
            withInMemoryIndexer $ \h -> do
                xs <- snapshotAt h (mkAddr 0xAA 29)
                xs `shouldBe` []

        it "round-trips a single create at one address" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin = TxIn (BS.replicate 32 0x11) 0
                    txout = TxOut "value-bytes-0"
                applyAtSlot h (SlotNo 1) testBlockHash [UtxoCreate txin addr txout]
                xs <- snapshotAt h addr
                xs `shouldBe` [(txin, txout)]

        it "returns entries in ascending TxIn order" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mkRow tid ix payload =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) ix)
                            addr
                            (TxOut payload)
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [ mkRow 0x33 5 "c"
                    , mkRow 0x11 0 "a"
                    , mkRow 0x22 0 "b"
                    ]
                xs <- snapshotAt h addr
                fmap (txInId . fst) xs
                    `shouldBe` [ BS.replicate 32 0x11
                               , BS.replicate 32 0x22
                               , BS.replicate 32 0x33
                               ]

        it "scopes scans to the queried address only" $
            withInMemoryIndexer $ \h -> do
                let a1 = mkAddr 0xAA 29
                    a2 = mkAddr 0xBB 29
                    txin = TxIn (BS.replicate 32 0x10) 0
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [ UtxoCreate txin a1 (TxOut "for-a1")
                    , UtxoCreate txin a2 (TxOut "for-a2")
                    ]
                xs1 <- snapshotAt h a1
                xs2 <- snapshotAt h a2
                xs1 `shouldBe` [(txin, TxOut "for-a1")]
                xs2 `shouldBe` [(txin, TxOut "for-a2")]

        it "scopes scans across mixed address lengths" $
            withInMemoryIndexer $ \h -> do
                let a29 = mkAddr 0xCC 29
                    a60 = mkAddr 0xCC 60
                    txin = TxIn (BS.replicate 32 0x44) 0
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [ UtxoCreate txin a29 (TxOut "29")
                    , UtxoCreate txin a60 (TxOut "60")
                    ]
                xs29 <- snapshotAt h a29
                xs60 <- snapshotAt h a60
                xs29 `shouldBe` [(txin, TxOut "29")]
                xs60 `shouldBe` [(txin, TxOut "60")]

        it "spends the right entry and leaves siblings alone" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin1 = TxIn (BS.replicate 32 0x11) 0
                    txin2 = TxIn (BS.replicate 32 0x22) 0
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [ UtxoCreate txin1 addr (TxOut "v1")
                    , UtxoCreate txin2 addr (TxOut "v2")
                    ]
                applyAtSlot h (SlotNo 2) testBlockHash [UtxoSpend txin1]
                xs <- snapshotAt h addr
                xs `shouldBe` [(txin2, TxOut "v2")]

        it "spending an unknown TxIn is a no-op" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin1 = TxIn (BS.replicate 32 0x11) 0
                    txin2 = TxIn (BS.replicate 32 0x99) 0
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [UtxoCreate txin1 addr (TxOut "v")]
                applyAtSlot h (SlotNo 2) testBlockHash [UtxoSpend txin2]
                xs <- snapshotAt h addr
                xs `shouldBe` [(txin1, TxOut "v")]

    describe "rollbackTo" $ do
        it "is a no-op when no slots exist above target" $
            withInMemoryIndexer $ \h -> do
                rollbackTo h (SlotNo 100)
                xs <- snapshotAt h (mkAddr 0xAA 29)
                xs `shouldBe` []

        it "undoes a single-slot create" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin = TxIn (BS.replicate 32 0x11) 0
                applyAtSlot
                    h
                    (SlotNo 5)
                    testBlockHash
                    [UtxoCreate txin addr (TxOut "v")]
                rollbackTo h (SlotNo 4)
                xs <- snapshotAt h addr
                xs `shouldBe` []

        it "preserves slots at-or-below the target" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                applyAtSlot h (SlotNo 4) testBlockHash [mk 0x04]
                rollbackTo h (SlotNo 2)
                xs <- snapshotAt h addr
                fmap (txInId . fst) xs
                    `shouldBe` [ BS.replicate 32 0x01
                               , BS.replicate 32 0x02
                               ]

        it "restores a spent UTxO" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin = TxIn (BS.replicate 32 0x11) 0
                applyAtSlot
                    h
                    (SlotNo 1)
                    testBlockHash
                    [UtxoCreate txin addr (TxOut "v")]
                applyAtSlot h (SlotNo 2) testBlockHash [UtxoSpend txin]
                rollbackTo h (SlotNo 1)
                xs <- snapshotAt h addr
                xs `shouldBe` [(txin, TxOut "v")]

        it "is idempotent at the same target" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    txin = TxIn (BS.replicate 32 0x11) 0
                applyAtSlot
                    h
                    (SlotNo 5)
                    testBlockHash
                    [UtxoCreate txin addr (TxOut "v")]
                rollbackTo h (SlotNo 3)
                rollbackTo h (SlotNo 3)
                xs <- snapshotAt h addr
                xs `shouldBe` []

    describe "pruneRollbacks (count-based finality cull)" $ do
        it "is a no-op on an empty rollback log" $
            withInMemoryIndexer $ \h -> do
                deleted <- pruneRollbacks h 100
                deleted `shouldBe` 0

        it "is a no-op while count <= maxKeep" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                deleted <- pruneRollbacks h 3
                deleted `shouldBe` 0

        it "drops the oldest entries down to maxKeep" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                applyAtSlot h (SlotNo 4) testBlockHash [mk 0x04]
                applyAtSlot h (SlotNo 5) testBlockHash [mk 0x05]
                deleted <- pruneRollbacks h 2
                deleted `shouldBe` 3
                -- Surviving rollback entries cover slots 4..5
                -- only — anything older is now unreachable, so a
                -- rollback to slot 0 only undoes the last two.
                rollbackTo h (SlotNo 0)
                xs <- snapshotAt h addr
                fmap (txInId . fst) xs
                    `shouldBe` [ BS.replicate 32 0x01
                               , BS.replicate 32 0x02
                               , BS.replicate 32 0x03
                               ]

        it "is idempotent (second call deletes nothing)" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                first <- pruneRollbacks h 1
                second <- pruneRollbacks h 1
                first `shouldBe` 2
                second `shouldBe` 0

        it "leaves the address index untouched" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                _ <- pruneRollbacks h 1
                xs <- snapshotAt h addr
                fmap (txInId . fst) xs
                    `shouldBe` [ BS.replicate 32 0x01
                               , BS.replicate 32 0x02
                               , BS.replicate 32 0x03
                               ]

        it "stays consistent across rollback + prune" $
            withInMemoryIndexer $ \h -> do
                let addr = mkAddr 0xAA 29
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                applyAtSlot h (SlotNo 1) testBlockHash [mk 0x01]
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x02]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x03]
                rollbackTo h (SlotNo 1)
                applyAtSlot h (SlotNo 2) testBlockHash [mk 0x12]
                applyAtSlot h (SlotNo 3) testBlockHash [mk 0x13]
                applyAtSlot h (SlotNo 4) testBlockHash [mk 0x14]
                -- Three apply + one rollback removed two from the
                -- log; a fourth-keep prune now sees count = 4
                -- and is a no-op.
                deleted <- pruneRollbacks h 4
                deleted `shouldBe` 0

{- | Build a synthetic 'Address' of the given length with
a fixed body byte. Lets tests construct Shelley-shaped
(29-byte) and Byron-shaped (60-byte) addresses without
pulling ledger types into the indexer's test deps.
-}
mkAddr :: Int -> Int -> Address
mkAddr body len = Address (BS.replicate len (fromIntegral body))

{- | A constant 32-byte block hash for tests where the
block hash isn't load-bearing.
-}
testBlockHash :: BlockHash
testBlockHash = BlockHash (BS.replicate 32 0)
