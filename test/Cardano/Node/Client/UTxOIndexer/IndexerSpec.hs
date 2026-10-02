{-# LANGUAGE LambdaCase #-}

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

import Cardano.Node.Client.BlockIndexer.Handler (
    IndexerHandler,
 )
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
 )
import Cardano.Node.Client.UTxOIndexer.Follower (
    InterestSet (..),
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AssetQueryUnavailable (..),
    BuildCoverage (..),
    BuildCoverageRefusal (..),
    IndexerHandle (..),
    StoreCoverage (..),
    UtxoOp (..),
    decodeBuildCoverage,
    encodeBuildCoverage,
    liveUtxoHandler,
    withInMemoryIndexer,
    withInMemoryIndexerRunner,
 )
import Cardano.Node.Client.UTxOIndexer.StoreFixture (dumpStore)
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Control.Monad (forM_, when)
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Word (Word32, Word64)
import Database.KV.Transaction (
    RunTransaction (..),
    insert,
    query,
 )
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldReturn,
    shouldSatisfy,
 )
import Test.QuickCheck (
    Gen,
    arbitrary,
    checkCoverage,
    choose,
    conjoin,
    counterexample,
    cover,
    forAll,
    listOf,
    oneof,
    property,
    vectorOf,
    (.&&.),
    (===),
 )

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer.Indexer" $ do
    describe "liveUtxoHandler" $
        it "is exposed as the UTxO block-indexer handler" $ do
            let _handler :: IndexerHandler Cols [UtxoOp]
                _handler = liveUtxoHandler IndexAll
            pure () :: IO ()

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

    buildCoverageSpec

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

-- * Build-coverage record

buildCoverageSpec :: Spec
buildCoverageSpec = describe "build-coverage record" $ do
    describe "encoding" $ do
        it "decodes what it encodes, for every start and address set" $
            property $
                checkCoverage $
                    forAll genBuildCoverage $ \c ->
                        cover 30 (setSize c > 1) "more than one address" $
                            cover 20 (isJust (bcStartPoint c)) "a start point" $
                                decodeBuildCoverage (encodeBuildCoverage c) === Just c

        it "lays the record out as version, start, then addresses in ascending order" $ do
            encodeBuildCoverage (BuildCoverage Nothing IndexAll)
                `shouldBe` BS.pack [1, 0, 0]
            encodeBuildCoverage layoutCoverage `shouldBe` layoutBytes
            decodeBuildCoverage layoutBytes `shouldBe` Just layoutCoverage

        it "refuses every strict prefix and every extension of a record" $
            forAll genBuildCoverage $ \c ->
                let bytes = encodeBuildCoverage c
                 in counterexample ("record " <> show bytes) $
                        (BS.length bytes >= 3)
                            .&&. conjoin
                                ( [ decodeBuildCoverage (BS.take n bytes) === Nothing
                                  | n <- [0 .. BS.length bytes - 1]
                                  ]
                                    <> [ decodeBuildCoverage (BS.snoc bytes b) === Nothing
                                       | b <- [0, 1, 0xFF]
                                       ]
                                )

        it "refuses another version, an unsorted or repeated address set and a wrong count" $
            forM_ malformedRecords $ \bytes ->
                decodeBuildCoverage bytes `shouldBe` Nothing

    describe "claimBuildCoverage" $ do
        it "records the session's coverage on an empty store" $
            forM_ claimCoverages $ \c ->
                withInMemoryIndexerRunner $ \h runner -> do
                    claimBuildCoverage h c `shouldReturn` Right (CoverageRecorded c)
                    record <- storedRecord runner
                    (decodeBuildCoverage =<< record) `shouldBe` Just c

        it "serves the recorded coverage to an equal session and writes nothing" $
            forM_ claimCoverages $ \c ->
                withInMemoryIndexerRunner $ \h runner -> do
                    _ <- claimBuildCoverage h c
                    applyAtSlot h (SlotNo 7) testBlockHash [createAt 0x07]
                    before <- dumpStore runner
                    claimBuildCoverage h c `shouldReturn` Right (CoverageRecorded c)
                    dumpStore runner `shouldReturn` before

        it "refuses a different session naming both coverages, on an empty or a non-empty store, and writes nothing" $
            forM_ [(a, b) | a <- claimCoverages, b <- claimCoverages, a /= b] $ \(a, b) ->
                forM_ [False, True] $ \populated ->
                    withInMemoryIndexerRunner $ \h runner -> do
                        claimBuildCoverage h a `shouldReturn` Right (CoverageRecorded a)
                        when populated $
                            applyAtSlot h (SlotNo 7) testBlockHash [createAt 0x07]
                        before <- dumpStore runner
                        claimBuildCoverage h b
                            `shouldReturn` Left BuildCoverageMismatch{recorded = a, requested = b}
                        dumpStore runner `shouldReturn` before

        it "refuses an undecodable record on an empty or a non-empty store, keeping its bytes" $
            forM_ malformedRecords $ \bytes ->
                forM_ [False, True] $ \populated ->
                    withInMemoryIndexerRunner $ \h runner -> do
                        runTransaction runner (insert MetaCol recordKey bytes)
                        when populated $
                            applyAtSlot h (SlotNo 7) testBlockHash [createAt 0x07]
                        before <- dumpStore runner
                        claimBuildCoverage h someCoverage
                            `shouldReturn` Left
                                BuildCoverageUndecodable{raw = bytes, requested = someCoverage}
                        dumpStore runner `shouldReturn` before

        it "states unrecorded for a non-empty store without a record, and writes nothing" $
            forM_ [minBound .. maxBound] $ \contents -> forM_ claimCoverages $ \c ->
                withInMemoryIndexerRunner $ \h runner -> do
                    holding h runner contents
                    before <- dumpStore runner
                    outcome <- claimBuildCoverage h c
                    (contents, outcome) `shouldBe` (contents, Right CoverageUnrecorded)
                    dumpStore runner `shouldReturn` before

        it "never rewrites or deletes the record, whatever the store goes through" $
            withInMemoryIndexerRunner $ \h runner -> do
                claimBuildCoverage h someCoverage
                    `shouldReturn` Right (CoverageRecorded someCoverage)
                record <- storedRecord runner
                record `shouldSatisfy` isJust
                applyAtSlot h (SlotNo 7) testBlockHash [createAt 0x07]
                applyAtSlot h (SlotNo 8) testBlockHash [createAt 0x08]
                -- an output whose bytes fail asset extraction drops the
                -- asset-index marker from the same column
                applyAtSlot
                    h
                    (SlotNo 9)
                    testBlockHash
                    [UtxoCreate (TxIn (BS.replicate 32 0x09) 0) (mkAddr 0xAA 29) (TxOut "\x80")]
                assetUtxos h (PolicyId (BS.replicate 28 0x11)) (AssetName "tok")
                    >>= (`shouldBe` Left AssetIndexAbsent) . either Left (const (Right ()))
                rollbackTo h (SlotNo 8)
                _ <- pruneRollbacks h 1
                claimBuildCoverage h someCoverage
                    `shouldReturn` Right (CoverageRecorded someCoverage)
                refused <- claimBuildCoverage h (BuildCoverage Nothing IndexAll)
                refused `shouldSatisfy` isLeft
                storedRecord runner `shouldReturn` record
  where
    setSize c = case bcInterestSet c of
        IndexAll -> 0
        IndexAddressSet s -> Set.size s

-- | The record's key in the metadata column.
recordKey :: ByteString
recordKey = "build-coverage"

storedRecord :: RunTransaction IO cf Cols op -> IO (Maybe ByteString)
storedRecord runner = runTransaction runner (query MetaCol recordKey)

createAt :: Int -> UtxoOp
createAt tid =
    UtxoCreate
        (TxIn (BS.replicate 32 (fromIntegral tid)) 0)
        (mkAddr 0xAA 29)
        (TxOut (BS.singleton (fromIntegral tid)))

someCoverage :: BuildCoverage
someCoverage = BuildCoverage (Just pointA) (IndexAddressSet setA)

{- | Sessions that differ by start (origin, a point, the same slot with
another hash, another slot) and by addresses (all, two sets of two
sharing one address).
-}
claimCoverages :: [BuildCoverage]
claimCoverages =
    [ BuildCoverage Nothing IndexAll
    , BuildCoverage (Just pointA) IndexAll
    , BuildCoverage (Just pointA') IndexAll
    , BuildCoverage (Just pointB) IndexAll
    , BuildCoverage Nothing (IndexAddressSet setA)
    , BuildCoverage Nothing (IndexAddressSet setB)
    , BuildCoverage (Just pointA) (IndexAddressSet setA)
    ]

pointA, pointA', pointB :: (SlotNo, BlockHash)
pointA = (SlotNo 100, BlockHash (BS.replicate 32 0xA1))
pointA' = (SlotNo 100, BlockHash (BS.replicate 32 0xA2))
pointB = (SlotNo 200, BlockHash (BS.replicate 32 0xA1))

setA, setB :: Set.Set Address
setA = Set.fromList [mkAddr 0x61 29, mkAddr 0x62 29]
setB = Set.fromList [mkAddr 0x61 29, mkAddr 0x63 29]

genBuildCoverage :: Gen BuildCoverage
genBuildCoverage = BuildCoverage <$> genStart <*> genInterest
  where
    genStart =
        oneof
            [ pure Nothing
            , Just <$> ((,) . SlotNo <$> arbitrary <*> (BlockHash <$> genBytes 40))
            ]
    genInterest =
        oneof
            [ pure IndexAll
            , IndexAddressSet . Set.fromList <$> listOf (Address <$> genBytes 60)
            ]
    genBytes n = choose (0, n) >>= \k -> BS.pack <$> vectorOf k arbitrary

-- | A record with a start point and two addresses given out of order.
layoutCoverage :: BuildCoverage
layoutCoverage =
    BuildCoverage
        (Just (SlotNo 0x0102030405060708, BlockHash (BS.pack [0xA0 .. 0xBF])))
        (IndexAddressSet (Set.fromList [Address (BS.pack [0x61, 2]), Address (BS.pack [0x61, 1, 9])]))

-- | 'layoutCoverage' as the data model lays it out.
layoutBytes :: ByteString
layoutBytes =
    BS.concat
        [ BS.pack [1]
        , BS.pack [1]
        , u64 0x0102030405060708
        , u32 32
        , BS.pack [0xA0 .. 0xBF]
        , BS.pack [1]
        , u32 2
        , u32 3
        , BS.pack [0x61, 1, 9]
        , u32 2
        , BS.pack [0x61, 2]
        ]

-- | Records the data model does not describe.
malformedRecords :: [ByteString]
malformedRecords =
    [ BS.empty
    , BS.pack [2, 0, 0]
    , BS.pack [0, 0, 0]
    , BS.pack [1, 2, 0]
    , BS.pack [1, 0, 2]
    , BS.pack [1, 1] <> u64 5 <> u32 33 <> BS.replicate 32 0
    , BS.pack [1, 0, 1] <> u32 2 <> address [0x62] <> address [0x61]
    , BS.pack [1, 0, 1] <> u32 2 <> address [0x61] <> address [0x61]
    , BS.pack [1, 0, 1] <> u32 3 <> address [0x61] <> address [0x62]
    , BS.pack [1, 0, 1] <> u32 1 <> address [0x61] <> address [0x62]
    ]
  where
    address bytes = u32 (fromIntegral (length bytes)) <> BS.pack bytes

u32 :: Word32 -> ByteString
u32 w = BS.pack [fromIntegral (w `shiftR` s) | s <- [24, 16, 8, 0]]

u64 :: Word64 -> ByteString
u64 w = BS.pack [fromIntegral (w `shiftR` s) | s <- [56, 48 .. 0]]

-- | What a store without a record holds, each making it non-empty.
data Holding
    = -- | A live output and the rollback-log entry of its block.
      LiveOutputAndEntry
    | -- | A rollback-log entry, no live output.
      EntryOnly
    | -- | A live-output row, no rollback-log entry.
      OutputRowOnly
    deriving stock (Show, Eq, Enum, Bounded)

holding :: IndexerHandle -> RunTransaction IO cf Cols op -> Holding -> IO ()
holding h runner = \case
    LiveOutputAndEntry -> applyAtSlot h (SlotNo 7) testBlockHash [createAt 0x07]
    EntryOnly -> do
        applyAtSlot h (SlotNo 7) testBlockHash []
        snapshotAt h (mkAddr 0xAA 29) `shouldReturn` []
        getRollbackHistory h >>= (`shouldSatisfy` (not . null))
    OutputRowOnly -> do
        runTransaction runner $
            insert TxInCol (TxIn (BS.replicate 32 0x07) 0) (mkAddr 0xAA 29)
        getRollbackHistory h `shouldReturn` []
