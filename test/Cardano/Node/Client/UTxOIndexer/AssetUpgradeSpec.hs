{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.AssetUpgradeSpec
Description : Asset index across restart and the in-place upgrade
License     : Apache-2.0

Drives real RocksDB directories through close, reopen and resume,
and through the explicit upgrade of a store that predates the asset
index: a directory written with the four pre-change column families.

Expected values come from producers at run time: a never-closed store
fed the same blocks, the ledger's own decoding of the live outputs'
stored bytes, the store's own resume points, and the answers the same
store gave before the upgrade. The fixtures exercise many holders of
several assets under several policies.
-}
module Cardano.Node.Client.UTxOIndexer.AssetUpgradeSpec (spec) where

import Cardano.Chain.Common qualified as ByronCommon
import Cardano.Crypto.Hash.Class (Hash (UnsafeHash))
import Cardano.Ledger.Address (
    Addr (..),
    BootstrapAddress (..),
 )
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.Binary (
    DecoderError,
    decCBOR,
    decodeFullDecoder,
    serialize',
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AssetMatch (..),
    AssetQueryUnavailable (..),
    AssetSnapshot (..),
    AwaitObservation,
    IndexerFollowerState,
    IndexerHandle (..),
    OpenOptions (..),
    UtxoOp (..),
    defaultOpenOptions,
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
    withRocksDBIndexerRunner,
    withRocksDBIndexerRunnerWith,
    withRocksDBIndexerWith,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    AssetKey (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    encodeLine,
    hex,
    requestLine,
    withSocketServer,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Exception (IOException, try)
import Control.Monad (foldM, forM, forM_, unless, void, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Default.Class (def)
import Data.Either (isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Database.KV.Cursor (Cursor, Entry (..), firstEntry, nextEntry)
import Database.KV.Database (Codecs, KV, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    DMap,
    DSum ((:=>)),
    RunTransaction (..),
    Transaction,
    delete,
    fromList,
    insert,
    iterating,
    newRunTransaction,
    query,
 )
import Database.RocksDB (
    Config (..),
    columnFamilies,
    iterEntry,
    iterFirst,
    iterNext,
    iterValid,
    withDBCF,
    withIterCF,
 )
import Lens.Micro ((^.))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldReturn,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer asset index restart and upgrade" $ do
        describe "restart (U1)" $
            it "close, reopen and resume answer like a never-closed store" $
                withSystemTempDirectory "asset-restart" restartMatchesNeverClosed

        describe "upgrade result (U2)" $ do
            it "leaves exactly the rows the live outputs derive, with the follower interleaved" $
                withSystemTempDirectory "asset-upgrade-interleaved" upgradeUnderFollower
            it "rebuilds an incomplete six-family store and sweeps its leftover rows" $
                withSystemTempDirectory "asset-upgrade-sweep" upgradeSweepsLeftovers

        describe "answers while rebuilding (U3)" $
            it
                "a store carrying the rebuild key answers rebuilding, typed and on the wire"
                rebuildKeyAnswersRebuilding

        describe "every family set an upgrade can leave (U4, U5)" $
            it "opens with and without the request, keeping a pre-change store degraded" $
                withSystemTempDirectory "asset-shapes" everyShapeOpens

        describe "interruption (U5)" $
            it "an upgrade closed at transaction boundaries completes on later opens" $
                withSystemTempDirectory "asset-interrupted" interruptedUpgradeCompletes

        describe "pre-change families (U6)" $
            it "the upgrade changes no byte of the four pre-change families" $
                withSystemTempDirectory "asset-upgrade-bytes" upgradeKeepsPreChangeBytes

        describe "other requests (U7)" $
            it "utxos_at, await and ready answer the same before, during and after" $
                withSystemTempDirectory "asset-upgrade-compat" upgradeKeepsOtherAnswers

        describe "request on a complete or new store (U9)" $ do
            it "changes nothing on a complete store" $
                withSystemTempDirectory "asset-complete" requestOnCompleteStore
            it "changes nothing on a new store" $
                withSystemTempDirectory "asset-new" requestOnNewStore

        describe "extraction failure (U10)" $ do
            it "an undecodable live output leaves the index absent, never complete" $
                withSystemTempDirectory "asset-bad-output" undecodableOutputLeavesAbsent
            it "an undecodable follower create behind the cursor leaves the index absent" $
                withSystemTempDirectory "asset-bad-behind" (undecodableFollowerCreate Behind)
            it "an undecodable follower create ahead of the cursor leaves the index absent" $
                withSystemTempDirectory "asset-bad-ahead" (undecodableFollowerCreate Ahead)

-- * U1

restartMatchesNeverClosed :: FilePath -> IO ()
restartMatchesNeverClosed tmp = do
    reference <- withRocksDBIndexer (tmp </> "never-closed") $ \h -> do
        st <- newFollowerState h True >>= feedAll h restartBefore
        r0 <- assetAnswers h
        st' <- rollbackFollowerState h st (SlotNo lastBefore)
        (r0 :) <$> answersAfterEach h st' restartAfter
    withRocksDBIndexer (tmp </> "restarted") $ \h ->
        void (newFollowerState h True >>= feedAll h restartBefore)
    resumed <- withRocksDBIndexer (tmp </> "restarted") $ \h -> do
        points <- getResumePoints h
        take 1 points `shouldBe` [(SlotNo lastBefore, blockHashAt lastBefore)]
        st0 <- newFollowerState h True
        r0 <- assetAnswers h
        intersection <- case points of
            (slot, _) : _ -> pure slot
            [] -> fail "the restarted store has no resume point"
        st <- rollbackFollowerState h st0 intersection
        (r0 :) <$> answersAfterEach h st restartAfter
    resumed `shouldBe` reference
    -- Non-vacuity: every answer is a match list, some asset has more
    -- than one holder, and the holder restored by the rollback after
    -- the restart reports its creation in the first block.
    concat reference `shouldSatisfy` all isRight
    maximum [length (asMatches s) | Right s <- concat reference]
        `shouldSatisfy` (> 1)
    [ amCreatedSlot m
        | Right s <- concat (drop 1 reference)
        , m <- asMatches s
        , amTxIn m == holder 0x02
        ]
        `shouldSatisfy` (\xs -> not (null xs) && all (== SlotNo 1) xs)

-- | Blocks fed before the restart; the last one spends holder 0x02.
restartBefore :: [Event]
restartBefore =
    [ Block
        1
        [ create 0x01 [(p1, "tok", 10)]
        , create 0x02 [(p1, "tok", 20)]
        , create 0x03 [(p1, "tok", 30), (p2, "other", 5)]
        ]
    , Block 2 [create 0x04 [(p2, "tok", 7), (p1, "", 1)]]
    , Block 3 [UtxoSpend (holder 0x02), create 0x05 [(p1, "tok", 20)]]
    ]

-- | Events after the resume: a fork restoring the spent holder.
restartAfter :: [Event]
restartAfter =
    [ Rollback 2
    , Block 4 [UtxoSpend (holder 0x01), create 0x06 [(p1, "tok", 11), (p2, "other", 6)]]
    , Block 5 [UtxoSpend (holder 0x03)]
    ]

lastBefore :: Word64
lastBefore = last [s | Block s _ <- restartBefore]

data Event = Block Word64 [UtxoOp] | Rollback Word64

feedAll :: IndexerHandle -> [Event] -> IndexerFollowerState -> IO IndexerFollowerState
feedAll h events st0 = foldM (feed h) st0 events

feed :: IndexerHandle -> IndexerFollowerState -> Event -> IO IndexerFollowerState
feed h st = \case
    Block s ops ->
        fst <$> processFollowerBlock h st 100 True (SlotNo s) (blockHashAt s) ops
    Rollback s -> rollbackFollowerState h st (SlotNo s)

answersAfterEach ::
    IndexerHandle ->
    IndexerFollowerState ->
    [Event] ->
    IO [[Either AssetQueryUnavailable AssetSnapshot]]
answersAfterEach _ _ [] = pure []
answersAfterEach h st (e : es) = do
    st' <- feed h st e
    r <- assetAnswers h
    (r :) <$> answersAfterEach h st' es

assetAnswers :: IndexerHandle -> IO [Either AssetQueryUnavailable AssetSnapshot]
assetAnswers h = forM queriedAssets $ \(p, n) -> assetUtxos h (PolicyId p) (AssetName n)

-- * U2

{- | Follower blocks land on both sides of the backfill cursor while the
upgrade runs: creates (rows written only by maintenance when behind),
spends, and rollbacks restoring the spent holders. Retried on a fresh
store when a run did not witness both sides; exactness is checked on
every run.
-}
upgradeUnderFollower :: FilePath -> IO ()
upgradeUnderFollower tmp = attempt (1 :: Int)
  where
    attempt k = do
        let path = tmp </> ("db-" <> show k)
            seeds = seedEntries interleavedSeeds
        seedPreChange path seeds
        witnessed@(twoSided, restored, readsDuring) <-
            withRocksDBIndexerRunnerWith requested path $ \h runner -> do
                stop <- newIORef False
                duringReads <- newIORef (0 :: Int)
                reader <- async (rebuildReader h runner stop duringReads)
                (twoSided, restored) <-
                    timeout 120_000_000 (followerAcrossCursor h runner (maxSeedSlot seeds))
                        >>= maybe (fail "the follower never saw the rebuild end") pure
                waitComplete runner
                writeIORef stop True
                wait reader
                live <- liveOutputs runner
                let expected = expectedRows live
                assetRows runner `shouldReturn` expected
                forM_ queriedAssets $ \asset -> do
                    answer <- assetUtxos h (PolicyId (fst asset)) (AssetName (snd asset))
                    expectedAnswer h runner asset >>= (answer `shouldBe`)
                forM_ queriedAssets $ \(p, n) ->
                    length [() | AssetKey (PolicyId p') (AssetName n') _ <- Map.keys expected, p' == p, n' == n]
                        `shouldSatisfy` (> 1)
                (twoSided,restored,) <$> readIORef duringReads
        unless (twoSided >= 2 && restored >= 1 && readsDuring >= 1) $
            if k < 3
                then attempt (k + 1)
                else expectationFailure ("no interleaving on both sides of the cursor: " <> show witnessed)

{- | Run follower blocks until the rebuild completes. Each block spends a
seeded holder and creates a new holder just behind the backfill cursor
(proved by an untouched probe row the backfill already wrote, so a
backfill commit precedes it) and just ahead of it (proved by a probe
row still absent after the block commits); the rebuild key still
present after the block puts a backfill commit after it. Every other
two-sided block is rolled back, restoring both spent holders, and
re-checked. Returns the two-sided blocks and the two-sided rollbacks.
-}
followerAcrossCursor :: IndexerHandle -> RunTransaction IO cf Cols op -> Word64 -> IO (Int, Int)
followerAcrossCursor h runner base = go 0 (0, 0)
  where
    go j counts@(both, restored) = do
        (cursor, rebuilding) <- cursorState runner
        if not rebuilding
            then pure counts
            else do
                let slot = base + 1 + fromIntegral j
                    behind = [cursor - 7 | cursor >= 20]
                    ahead = [cursor + aheadGap | cursor + aheadGap + 20 < interleavedSeeds]
                    targets = behind ++ ahead
                applyAtSlot h (SlotNo slot) (blockHashAt slot) $
                    [UtxoSpend (seedTxIn (holderAtOrBelow x)) | x <- targets]
                        ++ [ UtxoCreate (freshAfter x) (addrOf 0x99) (freshOut j x)
                           | x <- targets
                           ]
                twoSided <- (not (null behind) &&) <$> stillAhead runner ahead
                rolledBack <-
                    if twoSided && even both
                        then rollbackTo h (SlotNo (slot - 1)) >> stillAhead runner ahead
                        else pure False
                go (j + 1) (both + fromEnum twoSided, restored + fromEnum rolledBack)

-- | Seeds in the interleaving runs, and the distance of an ahead target.
interleavedSeeds, aheadGap :: Int
interleavedSeeds = 6000
aheadGap = 1000

{- | The backfill cursor, located by the probe rows (seeds @5k + 1@, each
holding one @tok@ under @p1@, never touched by a follower): the index of
the first probe without its row, and whether the rebuild key is present.
-}
cursorState :: RunTransaction IO cf Cols op -> IO (Int, Bool)
cursorState runner =
    runTransaction runner $ do
        rebuilding <- isJust <$> query MetaCol rebuildKey
        let search lo hi
                | lo >= hi = pure lo
                | otherwise = do
                    let mid = (lo + hi) `div` 2
                    present <- isJust <$> query AssetIndex (probeKey (5 * mid + 1))
                    if present then search (mid + 1) hi else search lo mid
        k <- search 0 (interleavedSeeds `div` 5)
        pure (5 * k + 1, rebuilding)

-- | Whether the rebuild is still running and the cursor has not reached the ahead target.
stillAhead :: RunTransaction IO cf Cols op -> [Int] -> IO Bool
stillAhead _ [] = pure False
stillAhead runner (x : _) =
    runTransaction runner $ do
        rebuilding <- isJust <$> query MetaCol rebuildKey
        probe <- query AssetIndex (probeKey (holderAtOrBelow x - 1))
        pure (rebuilding && isNothing probe)

probeKey :: Int -> AssetKey
probeKey i = AssetKey (PolicyId p1) (AssetName "tok") (seedTxIn i)

-- | The largest seed index at or below @x@ holding two assets (@5k + 2@).
holderAtOrBelow :: Int -> Int
holderAtOrBelow x = x - ((x - 2) `mod` 5)

-- | A key sorting right after seed @x@'s outputs and before seed @x + 1@'s.
freshAfter :: Int -> TxIn
freshAfter x = TxIn (BS.take 31 (seedTid x) <> "\x5B") 0

freshOut :: Int -> Int -> TxOut
freshOut j x =
    ledgerOut
        (3_000_000 + toInteger (j * 10_000 + x))
        [(p1, "tok", fromIntegral j + 1), (p2, "other", 9)]

{- | Reads during the upgrade: any read followed by the rebuild key
still being present happened while rebuilding and must answer
'AssetIndexRebuilding'; the store never answers absent, and both
metadata keys never coexist.
-}
rebuildReader ::
    IndexerHandle ->
    RunTransaction IO cf Cols op ->
    IORef Bool ->
    IORef Int ->
    IO ()
rebuildReader h runner stop duringReads = loop
  where
    loop = do
        done <- readIORef stop
        unless done $ do
            r <- assetUtxos h (PolicyId p1) (AssetName "tok")
            (marker, rebuilding) <- metaState runner
            (marker && rebuilding) `shouldBe` False
            r `shouldSatisfy` either (== AssetIndexRebuilding) (const True)
            when rebuilding $ do
                r `shouldBe` Left AssetIndexRebuilding
                modifyIORef' duringReads (+ 1)
            loop

upgradeSweepsLeftovers :: FilePath -> IO ()
upgradeSweepsLeftovers tmp = do
    let path = tmp </> "db"
        seeds = seedEntries 600
        liveHolder = seedTxIn 1
    -- A six-family store whose index lost completeness and carries
    -- rows no live output derives: a row of a spent output, a row of
    -- an asset the output does not hold, and a wrong quantity.
    withRocksDBIndexerRunner path $ \_ runner ->
        runTransaction runner $ do
            forM_ seeds $ \s -> insertSeed s
            forM_ (nub (map sdSlot seeds)) insertBlockRow
            insert AssetIndex (AssetKey (PolicyId p1) (AssetName "tok") (holder 0xAB)) 99
            insert AssetIndex (AssetKey (PolicyId p2) (AssetName "zzz") liveHolder) 1
            insert AssetIndex (AssetKey (PolicyId p1) (AssetName "tok") liveHolder) 12345
            delete MetaCol markerKey
    withRocksDBIndexer path $ \h ->
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexAbsent
    withRocksDBIndexerRunnerWith requested path $ \_ runner -> do
        waitComplete runner
        live <- liveOutputs runner
        assetRows runner `shouldReturn` expectedRows live

-- * U3

rebuildKeyAnswersRebuilding :: IO ()
rebuildKeyAnswersRebuilding = do
    withInMemoryIndexerRunner $ \h runner -> do
        applyAtSlot h (SlotNo 1) (blockHashAt 1) [create 0x01 [(p1, "tok", 10)], create 0x02 [(p1, "tok", 3)]]
        -- Control: the complete store answers a match list.
        assetUtxos h (PolicyId p1) (AssetName "tok") >>= (`shouldSatisfy` isRight)
        runTransaction runner $ do
            delete MetaCol markerKey
            insert MetaCol rebuildKey "\x01"
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexRebuilding
        withServer h $ \sock ->
            requestLine sock (assetRequest p1 "tok") >>= expectReason "rebuilding"
        -- Precedence over an inconsistent row.
        runTransaction runner $ delete TxInCol (holder 0x01)
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexRebuilding
    -- Precedence over a missing indexed point.
    withInMemoryIndexerRunner $ \h runner -> do
        runTransaction runner $ insert MetaCol rebuildKey "\x01"
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexRebuilding

-- * U4, U5: every family set an upgrade can leave

{- | The on-disk shapes a pre-change store passes through when an
upgrade runs, or stops between any two of its steps: four families,
four plus the asset family (stopped between the two creations), six
families without metadata, and six with the rebuild key.
-}
data Shape = PreChange | AssetFamilyOnly | SixFamilies | Rebuilding
    deriving stock (Show, Enum, Bounded)

{- | Each shape, on a real directory, opens without the request (keeping
its families and pre-change rows when not yet rebuilding) and then
with it, ending complete with exactly the derived rows.
-}
everyShapeOpens :: FilePath -> IO ()
everyShapeOpens tmp = forM_ [minBound .. maxBound] $ \shape -> do
    let path = tmp </> show shape
        seeds = seedEntries 3000
        families = case shape of
            PreChange -> 4
            AssetFamilyOnly -> 5
            _ -> 6
    case shape of
        Rebuilding -> do
            seedStore preChangeFamilies path seeds
            withRocksDBIndexerWith requested path (\_ -> pure ())
            closedMetaState path `shouldReturn` (False, True)
        _ -> seedStore (take families fullFamilies) path seeds
    before <- dumpFamilies path (take families fullFamilies) 4
    withRocksDBIndexerWith defaultOpenOptions path $ \h -> do
        snapshotAt h (seedAddr 0)
            `shouldReturn` [(sdTxIn s, sdOut s) | s <- seeds, sdAddr s == seedAddr 0]
        answer <- assetUtxos h (PolicyId p1) (AssetName "tok")
        case shape of
            Rebuilding -> answer `shouldSatisfy` (/= Left AssetIndexAbsent)
            _ -> answer `shouldBe` Left AssetIndexAbsent
    case shape of
        Rebuilding -> pure ()
        _ -> do
            storeFamilies path `shouldReturn` families
            dumpFamilies path (take families fullFamilies) 4 `shouldReturn` before
    withRocksDBIndexerRunnerWith requested path $ \_ runner -> do
        waitComplete runner
        live <- liveOutputs runner
        assetRows runner `shouldReturn` expectedRows live
    storeFamilies path `shouldReturn` 6

-- * U5

interruptedUpgradeCompletes :: FilePath -> IO ()
interruptedUpgradeCompletes tmp = do
    let path = tmp </> "db"
    seedPreChange path (seedEntries 3000)
    -- Closed straight after the open that asked for the upgrade.
    withRocksDBIndexerWith requested path (\_ -> pure ())
    storeFamilies path `shouldReturn` 6
    interrupted <- newIORef (0 :: Int)
    let session :: Int -> IO ()
        session i = do
            (marker, rebuilding) <- closedMetaState path
            (marker && rebuilding) `shouldBe` False
            unless marker $ do
                when (i > 300) $ expectationFailure "the upgrade never completed"
                rebuilding `shouldBe` True
                modifyIORef' interrupted (+ 1)
                let options = if even i then requested else defaultOpenOptions
                withRocksDBIndexerRunnerWith options path $ \_ runner -> do
                    let progress = runTransaction runner (query MetaCol rebuildKey)
                    p0 <- progress
                    waitUntil "the rebuild to advance" 60 ((/= p0) <$> progress)
                session (i + 1)
    session 1
    readIORef interrupted >>= (`shouldSatisfy` (>= 2))
    withRocksDBIndexerRunner path $ \h runner -> do
        metaState runner `shouldReturn` (True, False)
        live <- liveOutputs runner
        assetRows runner `shouldReturn` expectedRows live
        forM_ queriedAssets $ \asset -> do
            answer <- assetUtxos h (PolicyId (fst asset)) (AssetName (snd asset))
            expectedAnswer h runner asset >>= (answer `shouldBe`)

-- * U6

upgradeKeepsPreChangeBytes :: FilePath -> IO ()
upgradeKeepsPreChangeBytes tmp = do
    let path = tmp </> "db"
    seedPreChange path (seedEntries 2000)
    before <- dumpFamilies path preChangeFamilies 4
    withRocksDBIndexerRunnerWith requested path $ \_ runner -> do
        waitComplete runner
        rows <- assetRows runner
        Map.size rows `shouldSatisfy` (> 1)
    storeFamilies path `shouldReturn` 6
    dumpFamilies path fullFamilies 4 `shouldReturn` before

-- * U7

-- | Typed snapshots, typed awaits, and the raw wire answers.
type Observed = ([[(TxIn, TxOut)]], [Maybe AwaitObservation], [ByteString])

upgradeKeepsOtherAnswers :: FilePath -> IO ()
upgradeKeepsOtherAnswers tmp = attempt (1 :: Int)
  where
    attempt k = do
        let path = tmp </> ("db-" <> show k)
        seedPreChange path (seedEntries 4000)
        before <- withRocksDBIndexer path $ \h -> withServer h (observe h)
        -- Non-vacuity: several outputs per probed address, every
        -- probed await answered.
        let (snaps, awaits, _) = before
        snaps `shouldSatisfy` all ((> 1) . length)
        awaits `shouldSatisfy` all isJust
        (during, rebuilding, typed, wire, after) <-
            withRocksDBIndexerRunnerWith requested path $ \h runner ->
                withServer h $ \sock -> do
                    during <- observe h sock
                    typed <- assetUtxos h (PolicyId p1) (AssetName "tok")
                    wire <- requestLine sock (assetRequest p1 "tok")
                    (_, rebuilding) <- metaState runner
                    waitComplete runner
                    after <- observe h sock
                    pure (during, rebuilding, typed, wire, after)
        during `shouldBe` before
        after `shouldBe` before
        if rebuilding
            then do
                typed `shouldBe` Left AssetIndexRebuilding
                expectReason "rebuilding" wire
            else
                if k < 3
                    then attempt (k + 1)
                    else expectationFailure "no observation fell inside the upgrade"

observe :: IndexerHandle -> FilePath -> IO Observed
observe h sock = do
    snaps <- mapM (snapshotAt h) probeAddresses
    awaits <- mapM (\t -> awaitTxIn h t (Just 1)) probeTxIns
    wire <-
        mapM
            (requestLine sock)
            ( [encodeLine ["utxos_at" .= hex (unAddress a)] | a <- probeAddresses]
                ++ [ encodeLine ["await" .= (hex tid <> "#" <> Text.pack (show ix)), "timeout_seconds" .= (1 :: Int)]
                   | TxIn tid ix <- probeTxIns
                   ]
                ++ [encodeLine ["ready" .= Aeson.Null]]
            )
    pure (snaps, awaits, wire)

probeAddresses :: [Address]
probeAddresses = map seedAddr [0, 1, 2]

probeTxIns :: [TxIn]
probeTxIns = map seedTxIn [1, 2000, 3999]

-- * U9

requestOnCompleteStore :: FilePath -> IO ()
requestOnCompleteStore tmp = do
    let path = tmp </> "db"
    withRocksDBIndexer path $ \h ->
        void (newFollowerState h True >>= feedAll h restartBefore)
    before <- dumpFamilies path fullFamilies 6
    withRocksDBIndexerRunnerWith requested path $ \h runner -> do
        metaState runner `shouldReturn` (True, False)
        assetAnswers h >>= (`shouldSatisfy` all isRight)
        threadDelay 200_000
        metaState runner `shouldReturn` (True, False)
    dumpFamilies path fullFamilies 6 `shouldReturn` before

requestOnNewStore :: FilePath -> IO ()
requestOnNewStore tmp = do
    withRocksDBIndexer (tmp </> "plain") (\_ -> pure ())
    plain <- dumpFamilies (tmp </> "plain") fullFamilies 6
    withRocksDBIndexerRunnerWith requested (tmp </> "new") $ \h runner -> do
        metaState runner `shouldReturn` (True, False)
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left NoIndexedPoint
        threadDelay 200_000
        metaState runner `shouldReturn` (True, False)
    dumpFamilies (tmp </> "new") fullFamilies 6 `shouldReturn` plain

-- * U10

undecodableOutputLeavesAbsent :: FilePath -> IO ()
undecodableOutputLeavesAbsent tmp = do
    let path = tmp </> "db"
        bad =
            Seed
                { sdTxIn = TxIn (BS.replicate 32 0xFF) 0
                , sdAddr = addrOf 0xFF
                , sdOut = TxOut "not-cbor"
                , sdSlot = 1
                }
    seedPreChange path (seedEntries 1000 ++ [bad])
    withRocksDBIndexerRunnerWith requested path $ \h runner -> do
        markerSeen <- newIORef False
        waitUntil "the upgrade to stop" 60 $ do
            (marker, rebuilding) <- metaState runner
            (marker && rebuilding) `shouldBe` False
            when marker $ writeIORef markerSeen True
            pure (not rebuilding)
        readIORef markerSeen `shouldReturn` False
        metaState runner `shouldReturn` (False, False)
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexAbsent
        -- The upgrade really ran: the outputs before the undecodable
        -- one got their rows.
        rows <- assetRows runner
        Map.null rows `shouldBe` False
    storeFamilies path `shouldReturn` 6
    withRocksDBIndexerRunnerWith defaultOpenOptions path $ \h runner -> do
        metaState runner `shouldReturn` (False, False)
        assetUtxos h (PolicyId p1) (AssetName "tok")
            `shouldReturn` Left AssetIndexAbsent

data Side = Behind | Ahead

{- | A follower create of undecodable bytes lands behind or ahead of the
backfill cursor during the upgrade; the rebuild then ends absent and
the marker is never seen. Behind: the cursor had passed the target
before the block. Ahead: the probe below the target is still absent at
the end. During: some probe never got its row, so the backfill was cut
short rather than completed. Retried on a fresh store when a run did
not witness its side.
-}
undecodableFollowerCreate :: Side -> FilePath -> IO ()
undecodableFollowerCreate side tmp = attempt (1 :: Int)
  where
    attempt k = do
        let path = tmp </> ("db-" <> show k)
            seeds = seedEntries interleavedSeeds
            slot = maxSeedSlot seeds + 1
        seedPreChange path seeds
        witnessed <- withRocksDBIndexerRunnerWith requested path $ \h runner -> do
            case side of
                Behind ->
                    waitUntil "the cursor to pass the first seeds" 60 $
                        (\(c, r) -> c >= 1000 || not r) <$> cursorState runner
                Ahead -> pure ()
            (cursor, rebuilding) <- cursorState runner
            let target = case side of
                    Behind -> cursor - 7
                    Ahead -> cursor + aheadGap
            applyAtSlot h (SlotNo slot) (blockHashAt slot) [UtxoCreate (freshAfter target) (addrOf 0x99) (TxOut "not-cbor")]
            markerSeen <- newIORef False
            waitUntil "the upgrade to stop" 60 $ do
                (marker, still) <- metaState runner
                when marker $ writeIORef markerSeen True
                pure (not still)
            readIORef markerSeen `shouldReturn` False
            metaState runner `shouldReturn` (False, False)
            assetUtxos h (PolicyId p1) (AssetName "tok")
                `shouldReturn` Left AssetIndexAbsent
            (cursorEnd, _) <- cursorState runner
            pure $
                rebuilding
                    && cursorEnd <= interleavedSeeds
                    && case side of
                        Behind -> cursor >= 20
                        Ahead -> cursorEnd <= holderAtOrBelow target - 1
        unless witnessed $
            if k < 3
                then attempt (k + 1)
                else expectationFailure "the create never landed on the intended side of the cursor"

-- * Seeded pre-change stores

data Seed = Seed
    { sdTxIn :: TxIn
    , sdAddr :: Address
    , sdOut :: TxOut
    , sdSlot :: Word64
    }

{- | @n@ live outputs in ascending key order: every fifth is ada-only,
the others hold one of several asset mixes, spread over seven
addresses and over one block per hundred outputs.
-}
seedEntries :: Int -> [Seed]
seedEntries n =
    [ Seed
        { sdTxIn = seedTxIn i
        , sdAddr = seedAddr i
        , sdOut = ledgerOut (1_000_000 + toInteger i) (assetsFor i)
        , sdSlot = 1 + fromIntegral (i `div` 100)
        }
    | i <- [0 .. n - 1]
    ]
  where
    assetsFor i = case i `mod` 5 of
        0 -> []
        1 -> [(p1, "tok", fromIntegral i + 1)]
        2 -> [(p1, "tok", fromIntegral i + 1), (p2, "other", 2)]
        3 -> [(p2, "tok", 3), (p1, "", 4)]
        _ -> [(p1, BS.replicate 32 0xEE, 5)]

seedTxIn :: Int -> TxIn
seedTxIn i = TxIn (seedTid i) (fromIntegral (i `mod` 3))

seedTid :: Int -> ByteString
seedTid i = BS.pack [fromIntegral (i `shiftR` s) | s <- [24, 16, 8, 0]] <> BS.replicate 28 0x5A

seedAddr :: Int -> Address
seedAddr i = Address (BS.cons 0x61 (BS.replicate 28 (fromIntegral (i `mod` 7))))

maxSeedSlot :: [Seed] -> Word64
maxSeedSlot = maximum . map sdSlot

{- | A directory with only the four column families that existed before
the asset index, populated through the pre-change codecs as the old
binary would have: live outputs, observations, and one rollback row
per block.
-}
seedPreChange :: FilePath -> [Seed] -> IO ()
seedPreChange = seedStore preChangeFamilies

{- | A new directory with the given families, the first four populated
as in 'seedPreChange' and any others left empty.
-}
seedStore :: [(String, Config)] -> FilePath -> [Seed] -> IO ()
seedStore families path seeds =
    withDBCF path def{createIfMissing = True} families $ \rdb -> do
        runner <-
            newRunTransaction
                (mkRocksDBDatabase rdb (mkColumns (columnFamilies rdb) preChangeCodecs))
        runTransaction runner $ do
            forM_ seeds insertSeed
            forM_ (nub (map sdSlot seeds)) insertBlockRow

insertSeed :: Seed -> TransactionIO cf op ()
insertSeed Seed{sdTxIn, sdAddr, sdOut, sdSlot} = do
    insert TxInCol sdTxIn sdAddr
    insert AddressIndex (AddrKey sdAddr sdTxIn) sdOut
    insert ObservationCol sdTxIn (SlotNo sdSlot, blockHashAt sdSlot)

insertBlockRow :: Word64 -> TransactionIO cf op ()
insertBlockRow s =
    insert
        RollbackCol
        (SlotNo s)
        RollbackPoint{rpInverses = [[]], rpMeta = Just (blockHashAt s)}

type TransactionIO cf op = Transaction IO cf Cols op

preChangeCodecs :: DMap Cols Codecs
preChangeCodecs =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        ]

preChangeFamilies :: [(String, Config)]
preChangeFamilies =
    [ ("utxo-indexer.txin", def)
    , ("utxo-indexer.address", def)
    , ("utxo-indexer.observation", def)
    , ("utxo-indexer.rollback", def)
    ]

fullFamilies :: [(String, Config)]
fullFamilies =
    preChangeFamilies
        ++ [("utxo-indexer.asset", def), ("utxo-indexer.meta", def)]

-- * Reading stores

{- | How many of the six families, in order, a closed store has: the
only prefix of the list it opens with (RocksDB refuses an open that
omits an existing family or lists a missing one).
-}
storeFamilies :: FilePath -> IO Int
storeFamilies path = go [6, 5, 4]
  where
    go [] = fail "the store opens with no prefix of the six families"
    go (n : rest) = do
        r <- try @IOException (withDBCF path def (take n fullFamilies) (\_ -> pure n))
        either (const (go rest)) pure r

-- | The raw key/value bytes of the first @k@ listed families of a closed store.
dumpFamilies :: FilePath -> [(String, Config)] -> Int -> IO [[(ByteString, ByteString)]]
dumpFamilies path families k =
    withDBCF path def families $ \rdb ->
        forM (take k (columnFamilies rdb)) $ \cf ->
            withIterCF rdb cf $ \iter -> iterFirst iter >> collect iter
  where
    collect iter = do
        valid <- iterValid iter
        if not valid
            then pure []
            else do
                e <- iterEntry iter
                iterNext iter
                maybe id (:) e <$> collect iter

-- | The metadata state of a closed six-family store: (marker, rebuild key).
closedMetaState :: FilePath -> IO (Bool, Bool)
closedMetaState path = do
    families <- dumpFamilies path fullFamilies 6
    let meta = Map.fromList (last families)
    pure (Map.member markerKey meta, Map.member rebuildKey meta)

-- | The metadata state of an open store: (marker, rebuild key).
metaState :: RunTransaction IO cf Cols op -> IO (Bool, Bool)
metaState runner =
    runTransaction runner $ do
        marker <- query MetaCol markerKey
        rebuilding <- query MetaCol rebuildKey
        pure (isJust marker, isJust rebuilding)

waitComplete :: RunTransaction IO cf Cols op -> IO ()
waitComplete runner =
    waitUntil "the upgrade to complete" 60 $ do
        (marker, rebuilding) <- metaState runner
        (marker && rebuilding) `shouldBe` False
        pure marker

waitUntil :: String -> Int -> IO Bool -> IO ()
waitUntil what seconds condition = do
    r <- timeout (seconds * 1_000_000) loop
    maybe (expectationFailure ("timed out waiting for " <> what)) pure r
  where
    loop = do
        ok <- condition
        unless ok (threadDelay 5_000 >> loop)

-- | Every live output, from the store's own live columns.
liveOutputs :: RunTransaction IO cf Cols op -> IO [(TxIn, TxOut)]
liveOutputs runner =
    runTransaction runner $ do
        live <- iterating TxInCol walkAll
        catMaybes
            <$> forM live (\(t, a) -> fmap (t,) <$> query AddressIndex (AddrKey a t))

assetRows :: RunTransaction IO cf Cols op -> IO (Map AssetKey Word64)
assetRows runner = Map.fromList <$> runTransaction runner (iterating AssetIndex walkAll)

walkAll :: (Monad m) => Cursor m (KV k v) [(k, v)]
walkAll = firstEntry >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey, entryValue}) =
        nextEntry >>= go ((entryKey, entryValue) : acc)

-- | The rows the live outputs derive, by the ledger's decoding of their bytes.
expectedRows :: [(TxIn, TxOut)] -> Map AssetKey Word64
expectedRows live =
    Map.fromList
        [ (AssetKey (PolicyId p) (AssetName n) t, q)
        | (t, out) <- live
        , ((p, n), q) <- Map.toList (ledgerAssets out)
        ]

{- | The answer the asset query owes for the store's own live data:
holders and quantities from the ledger's decoding of the stored bytes,
creation points from the observations, the point from the rollback
history.
-}
expectedAnswer ::
    IndexerHandle ->
    RunTransaction IO cf Cols op ->
    (ByteString, ByteString) ->
    IO (Either AssetQueryUnavailable AssetSnapshot)
expectedAnswer h runner asset = do
    live <- liveOutputs runner
    observations <- Map.fromList <$> runTransaction runner (iterating ObservationCol walkAll)
    history <- getRollbackHistory h
    point <- case [(s, bh) | (s, RollbackPoint{rpMeta = Just bh}) <- reverse history] of
        p : _ -> pure p
        [] -> fail "no applied block"
    pure $
        Right
            AssetSnapshot
                { asPoint = point
                , asMatches =
                    sortOn
                        amTxIn
                        [ AssetMatch
                            { amTxIn = t
                            , amTxOut = out
                            , amQuantity = q
                            , amCreatedSlot = s
                            , amCreatedBlockHash = bh
                            }
                        | (t, out) <- live
                        , Just q <- [Map.lookup asset (ledgerAssets out)]
                        , Just (s, bh) <- [Map.lookup t observations]
                        ]
                }

-- * Ledger-built outputs

ledgerAddr :: Addr
ledgerAddr =
    AddrBootstrap
        ( BootstrapAddress
            ( either
                (error . show)
                id
                ( ByronCommon.decodeAddressBase58
                    "DdzFFzCqrhsq3KjLtT51mESbZ4RepiHPzLqEhamexVFTJpGbCXmh7qSxnHvaL88QmtVTD1E1sjx8Z1ZNDhYmcBV38ZjDST9kYVxSkhcw"
                )
            )
        )

-- | Stored bytes of a ledger-built Conway output holding the given assets.
ledgerOut :: Integer -> [(ByteString, ByteString, Word64)] -> TxOut
ledgerOut coin assets =
    TxOut (serialize' (Ledger.eraProtVerLow @ConwayEra) (mkBasicTxOut @ConwayEra ledgerAddr value))
  where
    value =
        Mary.valueFromList
            (Coin coin)
            [ (Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort p))), Mary.AssetName (SBS.toShort n), toInteger q)
            | (p, n, q) <- assets
            ]

-- | The positive asset quantities the ledger reads from stored bytes.
ledgerAssets :: TxOut -> Map (ByteString, ByteString) Word64
ledgerAssets (TxOut raw) =
    case decodeFullDecoder
            (Ledger.eraProtVerLow @ConwayEra)
            "txout"
            decCBOR
            (BSL.fromStrict raw) ::
            Either DecoderError (Ledger.TxOut ConwayEra) of
        Left e -> error (show e)
        Right out ->
            let Mary.MaryValue _ multiAsset = out ^. Ledger.valueTxOutL
             in Map.fromList
                    [ ((SBS.fromShort p, SBS.fromShort n), fromInteger q)
                    | (Mary.PolicyID (ScriptHash (UnsafeHash p)), Mary.AssetName n, q) <-
                        Mary.flattenMultiAsset multiAsset
                    , q > 0
                    ]

-- * Wire

readyFixed :: ReadyStatus
readyFixed =
    ReadyStatus
        { rsReady = True
        , rsTipSlot = Just (SlotNo 20)
        , rsProcessedSlot = Just (SlotNo 12)
        , rsSlotsBehind = Just 8
        , rsUpstream = UpstreamConnected
        }

withServer :: IndexerHandle -> (FilePath -> IO a) -> IO a
withServer h = withSocketServer (\path -> runServer path h (pure readyFixed))

assetRequest :: ByteString -> ByteString -> ByteString
assetRequest p n =
    encodeLine
        [ "utxos_with_asset"
            .= Aeson.object ["policy_id" .= hex p, "asset_name" .= hex n]
        ]

expectReason :: Text.Text -> ByteString -> IO ()
expectReason reason resp =
    case Aeson.decodeStrict' resp of
        Just (Aeson.Object o) ->
            ( KM.lookup "error" o
            , KM.lookup "reason" o
            )
                `shouldBe` (Just "asset_index_unavailable", Just (Aeson.String reason))
        _ -> expectationFailure ("not an object: " <> show resp)

-- * Fixtures

requested :: OpenOptions
requested = OpenOptions{ooRebuildAssetIndex = True}

markerKey :: ByteString
markerKey = "asset-index"

rebuildKey :: ByteString
rebuildKey = "asset-index-rebuild"

p1, p2 :: ByteString
p1 = BS.replicate 28 0x11
p2 = BS.replicate 28 0x22

queriedAssets :: [(ByteString, ByteString)]
queriedAssets =
    [ (p1, "tok")
    , (p2, "other")
    , (p2, "tok")
    , (p1, "")
    , (p1, BS.replicate 32 0xEE)
    ]

holder :: Word8 -> TxIn
holder b = TxIn (BS.replicate 32 b) 0

addrOf :: Word8 -> Address
addrOf b = Address (BS.replicate 29 b)

create :: Word8 -> [(ByteString, ByteString, Word64)] -> UtxoOp
create b assets = UtxoCreate (holder b) (addrOf b) (ledgerOut (toInteger b * 1000) assets)

blockHashAt :: Word64 -> BlockHash
blockHashAt s = BlockHash (BS.replicate 32 (fromIntegral s))
