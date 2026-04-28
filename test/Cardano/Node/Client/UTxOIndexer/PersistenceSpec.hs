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
    ApplyConflict (..),
    AwaitObservation (..),
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
import Control.Exception (try)
import Data.ByteString qualified as BS
import Data.Word (Word64)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

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

        it "replaying same blocks from Origin is a silent no-op" $
            -- Mimic the daemon restarting from Origin against a
            -- populated DB: re-apply the same (slot, blockhash, ops)
            -- triples and verify the rollback log doesn't grow,
            -- the counter doesn't drift, and snapshotAt is stable.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    mk tid =
                        UtxoCreate
                            (TxIn (BS.replicate 32 tid) 0)
                            addr
                            (TxOut (BS.singleton tid))
                    blocks =
                        [ (SlotNo 1, testBlockHash, [mk 0x01])
                        , (SlotNo 2, testBlockHash, [mk 0x02])
                        , (SlotNo 3, testBlockHash, [mk 0x03])
                        ]
                    apply h =
                        mapM_
                            (\(s, b, o) -> applyAtSlot h s b o)
                            blocks
                withRocksDBIndexer dbPath $ \h -> apply h
                -- Reopen and replay the entire stream — every call
                -- should be a no-op.
                withRocksDBIndexer dbPath $ \h -> do
                    apply h
                    -- Counter unchanged: prune to keep 1 must
                    -- delete exactly 2, which only holds if the
                    -- replay didn't bump the in-memory counter.
                    deleted <- pruneRollbacks h 1
                    deleted `shouldBe` 2
                -- Reopen once more and verify the address index
                -- still has all three entries (replay didn't
                -- corrupt anything).
                withRocksDBIndexer dbPath $ \h -> do
                    xs <- snapshotAt h addr
                    fmap (txInId . fst) xs
                        `shouldBe` [ BS.replicate 32 0x01
                                   , BS.replicate 32 0x02
                                   , BS.replicate 32 0x03
                                   ]

        it "replaying from Origin after rollback-log prune does not resurrect spent UTxOs" $
            -- The replay guard cannot trust 'RollbackCol[slot]'
            -- in isolation: finality pruning (#83) drops the
            -- rollback rows of older finalized slots, so a
            -- daemon that restarted from Origin against a
            -- partially-pruned DB would re-apply the create
            -- whose row was pruned but skip the spend whose row
            -- survived, resurrecting the spent UTxO.
            --
            -- The guard uses 'RollbackCol''s @lastEntry@ as the
            -- watermark instead — anything @<= tipSlot@ counts
            -- as already applied even when its rollback row has
            -- been pruned.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x42) 0
                    create =
                        ( SlotNo 1
                        , BlockHash (BS.replicate 32 0x01)
                        , [UtxoCreate txin addr (TxOut "created")]
                        )
                    spend =
                        ( SlotNo 2
                        , BlockHash (BS.replicate 32 0x02)
                        , [UtxoSpend txin]
                        )
                    apply h (s, b, ops) = applyAtSlot h s b ops
                withRocksDBIndexer dbPath $ \h -> do
                    apply h create
                    apply h spend
                    snapshotAt h addr >>= (`shouldBe` [])
                    deleted <- pruneRollbacks h 1
                    deleted `shouldBe` 1
                withRocksDBIndexer dbPath $ \h -> do
                    apply h create
                    apply h spend
                    snapshotAt h addr >>= (`shouldBe` [])

        it "awaitTxIn returns immediately for an indexed TxIn after reopen" $
            -- The in-process @observedVar@ is empty after reopen.
            -- Persistent 'ObservationCol' must fill the gap so
            -- 'awaitTxIn' on an already-indexed unspent TxIn
            -- returns immediately rather than timing out.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x77) 0
                    txout = TxOut "value-await"
                    bh = BlockHash (BS.replicate 32 0xBB)
                withRocksDBIndexer dbPath $ \h ->
                    applyAtSlot
                        h
                        (SlotNo 7)
                        bh
                        [UtxoCreate txin addr txout]
                withRocksDBIndexer dbPath $ \h -> do
                    -- 1-second timeout: if the fast path is broken,
                    -- this returns Nothing; if it works, the call
                    -- returns immediately with the observation.
                    obs <- awaitTxIn h txin (Just 1)
                    obs `shouldBe` Just (mkObservation 7 bh txout)

        it "awaitTxIn after spend across reopen returns Nothing on timeout" $
            -- A TxIn that's been spent should not have a persistent
            -- observation — the spend deleted it. After reopen,
            -- 'awaitTxIn' falls back to the slow path and times out.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x88) 0
                    bh = BlockHash (BS.replicate 32 0xBB)
                withRocksDBIndexer dbPath $ \h -> do
                    applyAtSlot
                        h
                        (SlotNo 1)
                        bh
                        [UtxoCreate txin addr (TxOut "v")]
                    applyAtSlot
                        h
                        (SlotNo 2)
                        (BlockHash (BS.replicate 32 0xCC))
                        [UtxoSpend txin]
                withRocksDBIndexer dbPath $ \h -> do
                    obs <- awaitTxIn h txin (Just 1)
                    obs `shouldBe` Nothing

        it "same slot + different blockhash is rejected" $
            -- Two different blocks claiming the same slot is the
            -- "I'm on a different fork than what's persisted"
            -- signal. 'applyAtSlot' must throw 'ApplyConflict' and
            -- not corrupt state.
            withTempDB $ \dbPath -> do
                let addr = Address (BS.replicate 29 0xAA)
                    txin = TxIn (BS.replicate 32 0x11) 0
                    bh1 = BlockHash (BS.replicate 32 0xAA)
                    bh2 = BlockHash (BS.replicate 32 0xBB)
                withRocksDBIndexer dbPath $ \h ->
                    applyAtSlot
                        h
                        (SlotNo 5)
                        bh1
                        [UtxoCreate txin addr (TxOut "v1")]
                withRocksDBIndexer dbPath $ \h -> do
                    result <-
                        try @ApplyConflict $
                            applyAtSlot
                                h
                                (SlotNo 5)
                                bh2
                                [ UtxoCreate
                                    txin
                                    addr
                                    (TxOut "v2")
                                ]
                    result `shouldSatisfy` isApplyConflict
                    -- State at @addr@ must reflect the original
                    -- bh1 apply, not the rejected bh2 apply.
                    xs <- snapshotAt h addr
                    xs `shouldBe` [(txin, TxOut "v1")]
  where
    isApplyConflict (Left ApplyConflict{acSlot = SlotNo 5}) = True
    isApplyConflict _ = False

-- * Test helpers

withTempDB :: (FilePath -> IO a) -> IO a
withTempDB action =
    withSystemTempDirectory "utxo-indexer-rocksdb" $ \tmp ->
        action (tmp </> "db")

testBlockHash :: BlockHash
testBlockHash = BlockHash (BS.replicate 32 0)

mkObservation ::
    Word64 -> BlockHash -> TxOut -> AwaitObservation
mkObservation slot bh txOut =
    AwaitObservation
        { aoSlot = SlotNo slot
        , aoBlockHash = bh
        , aoTxOut = txOut
        }
