{- |
Module      : Cardano.Node.Client.UTxOIndexer.AssetIndexSpec
Description : Transactional asset index maintenance and typed read
License     : Apache-2.0

Drives the indexer through block scripts whose outputs are built by
the ledger, and checks the typed asset read against a pure model fold
over the same script: expected holders, quantities, bytes and creation
points all come from the script (built through the ledger) at run
time. Covers maintenance exactness, backend parity, rollback
provenance, replay\/divergent stability, concurrency, and the explicit
unavailability answers.
-}
module Cardano.Node.Client.UTxOIndexer.AssetIndexSpec (spec) where

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
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    ApplyConflict (..),
    AssetMatch (..),
    AssetQueryUnavailable (..),
    AssetSnapshot (..),
    AwaitObservation (..),
    IndexerHandle (..),
    InterestSet (..),
    UtxoOp (..),
    liveUtxoHandler,
    withFollowerHandlers,
    withInMemoryIndexer,
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
    mkAssetName,
    mkPolicyId,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Exception (IOException, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Default.Class (def)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sortOn)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word64, Word8)
import Database.KV.Database (Codecs, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    DMap,
    DSum ((:=>)),
    RunTransaction (..),
    delete,
    fromList,
    insert,
    newRunTransaction,
 )
import Database.RocksDB (
    Config (..),
    columnFamilies,
    withDBCF,
 )
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
    describe "Cardano.Node.Client.UTxOIndexer asset index" $ do
        describe "transactional maintenance against the model (I1)" $
            it "matches after create, move, split, partial spend and burn" $ do
                nonDegenerateWitness maintenanceScript allAssets
                multiHolderWitness maintenanceScript
                withInMemoryIndexer $ \h ->
                    runScriptAndCheck h maintenanceScript allAssets

        describe "replacement over a live TxIn (DM10)" $ do
            it "replaces and rollbacks reconcile both asset sets" $ do
                nonDegenerateWitness replacementScript [(p1Bytes, "old"), (p1Bytes, "new")]
                withInMemoryIndexer $ \h ->
                    runScriptAndCheck
                        h
                        replacementScript
                        [(p1Bytes, "old"), (p1Bytes, "new")]

            it "behaves identically on RocksDB" $
                withSystemTempDirectory "utxo-indexer-replace" $ \tmp -> do
                    memResults <-
                        withInMemoryIndexer $ \h ->
                            collectReplacementResults h
                    rocksResults <-
                        withRocksDBIndexer (tmp </> "db") $ \h ->
                            collectReplacementResults h
                    rocksResults `shouldBe` memResults

        describe "read shape (R3, R4, R6)" $
            it "returns every holder ascending with point and fields" $
                withInMemoryIndexer $ \h -> do
                    runScript h holdersScript
                    result <- assetUtxos h (polId p1Bytes) (name "tok")
                    result
                        `shouldBe` Right
                            ( AssetSnapshot
                                { asPoint =
                                    ( SlotNo lastSlot
                                    , BlockHash (hashOf lastSlot)
                                    )
                                , asMatches = expectedMatches
                                }
                            )
                    case result of
                        Right AssetSnapshot{asMatches = ms} -> do
                            -- Non-degeneracy: the multi-holder case
                            -- really observes more than one holder.
                            length ms `shouldSatisfy` (> 1)
                            fmap amTxIn ms
                                `shouldBe` sortOn id (fmap amTxIn ms)
                        Left e -> error (show e)

        describe "AddressIndex byte identity (I3)" $
            it "match bytes equal snapshotAt bytes for the same TxIn" $
                withInMemoryIndexer $ \h -> do
                    runScript h holdersScript
                    Right AssetSnapshot{asMatches = ms} <-
                        assetUtxos h (polId p1Bytes) (name "tok")
                    forM_ ms $ \AssetMatch{amTxIn, amTxOut} -> do
                        xs <- snapshotAt h (addrFor amTxIn)
                        [ out
                            | (t, out) <- xs
                            , t == amTxIn
                            ]
                            `shouldBe` [amTxOut]

        describe "rollback provenance (I4)" $
            it "restored output reports its original creation point" $ do
                nonDegenerateWitness provenanceScript [(p1Bytes, "tok")]
                multiHolderWitness provenanceScript
                withInMemoryIndexer $ \h ->
                    runScriptAndCheck h provenanceScript [(p1Bytes, "tok")]

        describe "replay and divergent blocks (I6)" $
            it "leave asset rows unchanged" $
                withInMemoryIndexer $ \h -> do
                    runScript h [provenanceFirstStep]
                    before <- assetUtxos h (polId p1Bytes) (name "tok")
                    runScript h [provenanceFirstStep]
                    after <- assetUtxos h (polId p1Bytes) (name "tok")
                    after `shouldBe` before
                    let divergent =
                            Step
                                { stSlot = 1
                                , stHash = BS.replicate 32 0xEE
                                , stOps =
                                    [ Create
                                        (tx 0x99)
                                        (addrOf 0x99)
                                        (produced [(p1Bytes, "tok", 1)])
                                    ]
                                }
                    r <- try @ApplyConflict (applyStep h divergent)
                    r `shouldSatisfy` isConflictAt1
                    afterConflict <-
                        assetUtxos h (polId p1Bytes) (name "tok")
                    afterConflict `shouldBe` before

        describe "in-memory and RocksDB parity (I2)" $
            it "give identical answers for the same script" $
                withSystemTempDirectory "utxo-indexer-parity" $ \tmp -> do
                    memResults <-
                        withInMemoryIndexer $ \h ->
                            collectResults h parityScript
                    rocksResults <-
                        withRocksDBIndexer (tmp </> "db") $ \h ->
                            collectResults h parityScript
                    rocksResults `shouldBe` memResults

        describe "concurrent snapshots (I5)" $
            it "every snapshot equals the model state at its point" $
                withInMemoryIndexer $ \h -> do
                    let recorded = recordedStates concurrencyScript
                    Map.size recorded `shouldSatisfy` (> 1)
                    done <- newIORef False
                    readsTotal <- newIORef (0 :: Int)
                    readsDuringWriter <- newIORef (0 :: Int)
                    pointsSeen <- newIORef Set.empty
                    writer <- async (runScriptDelayed h concurrencyScript)
                    readers <-
                        mapM
                            (\_ -> async (reader h recorded done readsTotal readsDuringWriter pointsSeen))
                            [1 .. 4 :: Int]
                    wait writer
                    writeIORef done True
                    mapM_ wait readers
                    -- Non-vacuous contention: the readers really read,
                    -- overlapped the writer, and saw more than one
                    -- indexed point.
                    total <- readIORef readsTotal
                    during <- readIORef readsDuringWriter
                    seen <- readIORef pointsSeen
                    total `shouldSatisfy` (>= 8)
                    during `shouldSatisfy` (>= 2)
                    Set.size seen `shouldSatisfy` (> 1)

        describe "explicit unavailability (I7)" $ do
            it "empty store answers NoIndexedPoint" $
                withInMemoryIndexer $ \h -> do
                    r <- assetUtxos h (polId p1Bytes) (name "tok")
                    r `shouldBe` Left NoIndexedPoint

            it "restoration-only store answers NoIndexedPoint" $
                withInMemoryIndexer $ \h -> do
                    st <- newFollowerState h True
                    (_st', processed) <-
                        processFollowerBlock
                            h
                            st
                            2
                            False
                            (SlotNo 1)
                            (BlockHash (BS.replicate 32 0x11))
                            []
                    processed `shouldBe` True
                    r <- assetUtxos h (polId p1Bytes) (name "tok")
                    r `shouldBe` Left NoIndexedPoint

            it "pre-change populated store answers AssetIndexAbsent" $
                withSystemTempDirectory "utxo-indexer-prechange" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    seedPreChangeStore dbPath
                    withRocksDBIndexer dbPath $ \h -> do
                        xs <- snapshotAt h preChangeAddr
                        xs `shouldBe` [(preChangeTxIn, preChangeOut)]
                        r <- assetUtxos h (polId p1Bytes) (name "tok")
                        r `shouldBe` Left AssetIndexAbsent

            it "degraded store keeps base behaviour and provenance, answers Absent" $
                withSystemTempDirectory "utxo-indexer-degraded" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    seedPreChangeStore dbPath
                    withRocksDBIndexer dbPath $ \h -> do
                        -- Apply, spend and roll back on the degraded
                        -- store exactly as on base: the spend inverse
                        -- carries provenance (tag 2) even here.
                        applyAtSlot
                            h
                            (SlotNo 8)
                            (BlockHash (hashOf 8))
                            [ UtxoCreate
                                (tx 0x88)
                                (addrOf 0x88)
                                (pTxOut (produced [(p1Bytes, "tok", 3)]))
                            ]
                        applyAtSlot
                            h
                            (SlotNo 9)
                            (BlockHash (hashOf 9))
                            [UtxoSpend (tx 0x88)]
                        rollbackTo h (SlotNo 8)
                        obs <- awaitTxIn h (tx 0x88) (Just 1)
                        obs
                            `shouldBe` Just
                                ( AwaitObservation
                                    { aoSlot = SlotNo 8
                                    , aoBlockHash = BlockHash (hashOf 8)
                                    , aoTxOut = pTxOut (produced [(p1Bytes, "tok", 3)])
                                    }
                                )
                        r <- assetUtxos h (polId p1Bytes) (name "tok")
                        r `shouldBe` Left AssetIndexAbsent

            it "the daemon follower configuration keeps going on a degraded store" $
                withSystemTempDirectory "utxo-indexer-degraded-follower" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    seedPreChangeStore dbPath
                    withRocksDBIndexer dbPath $ \h -> do
                        st0 <- newFollowerState h True
                        -- The daemon's own handler swap: the shipped
                        -- configuration installs the public handler
                        -- list over the follower state.
                        let st =
                                withFollowerHandlers
                                    IndexAll
                                    (liveUtxoHandler IndexAll :| [])
                                    st0
                        let out = pTxOut (produced [(p1Bytes, "tok", 7)])
                        (_st', processed) <-
                            processFollowerBlock
                                h
                                st
                                2
                                True
                                (SlotNo 12)
                                (BlockHash (hashOf 12))
                                [UtxoCreate (tx 0x66) (addrOf 0x66) out]
                        processed `shouldBe` True
                        snapshotAt h (addrOf 0x66)
                            `shouldReturn` [(tx 0x66, out)]
                        awaitTxIn h (tx 0x66) (Just 1)
                            `shouldReturn` Just
                                ( AwaitObservation
                                    { aoSlot = SlotNo 12
                                    , aoBlockHash = BlockHash (hashOf 12)
                                    , aoTxOut = out
                                    }
                                )
                        assetUtxos h (polId p1Bytes) (name "tok")
                            `shouldReturn` Left AssetIndexAbsent

            it "a caller-action failure after a degraded open propagates unchanged" $
                withSystemTempDirectory "utxo-indexer-action-err" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    seedPreChangeStore dbPath
                    r <-
                        try @IOException $
                            withRocksDBIndexer dbPath $ \_ ->
                                ioError (userError "action-marker-707")
                    case r of
                        Right () -> error "expected the action to fail"
                        Left e -> do
                            show e `shouldSatisfy` isInfixOf "action-marker-707"
                            show e
                                `shouldSatisfy` not . isInfixOf "Column family not found"

            it "a failing fallback rethrows the original open error" $
                withSystemTempDirectory "utxo-indexer-short-store" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    -- A store missing even base families: both the
                    -- full and the fallback open must fail, and the
                    -- original full-open error is the one that
                    -- escapes.
                    withDBCF
                        dbPath
                        def{createIfMissing = True}
                        [ ("utxo-indexer.txin", def)
                        , ("utxo-indexer.address", def)
                        ]
                        (\_ -> pure ())
                    original <-
                        try @IOException $
                            withDBCF dbPath def{createIfMissing = True} fullFamilies $
                                \_ -> pure ()
                    r <-
                        try @IOException $
                            withRocksDBIndexer dbPath (\_ -> pure ())
                    case (original, r) of
                        (Left e1, Left e2) -> show e2 `shouldBe` show e1
                        _ -> error "expected both opens to fail"

            it "a non-family open failure propagates unchanged" $
                withSystemTempDirectory "utxo-indexer-corrupt" $ \tmp -> do
                    let dbPath = tmp </> "db"
                    -- A non-empty directory that is not a RocksDB
                    -- store must fail with the original open error,
                    -- not fall back to the pre-change family list.
                    createDirectoryIfMissing True dbPath
                    writeFile (dbPath </> "CURRENT") "not a manifest"
                    writeFile (dbPath </> "junk") "garbage"
                    r <- try @IOException (withRocksDBIndexer dbPath (\_ -> pure ()))
                    case r of
                        Right () -> error "expected the open to fail"
                        Left e ->
                            show e `shouldSatisfy` not . isInfixOf "Column family not found"

            it "extraction failure on apply removes completeness" $
                withInMemoryIndexer $ \h -> do
                    runScript h [provenanceFirstStep]
                    applyAtSlot
                        h
                        (SlotNo 2)
                        (BlockHash (hashOf 2))
                        [ UtxoCreate
                            (tx 0x50)
                            (addrOf 0x50)
                            (TxOut "not-cbor")
                        ]
                    r <- assetUtxos h (polId p1Bytes) (name "tok")
                    r `shouldBe` Left AssetIndexAbsent

            it "extraction failure on spend removes completeness" $
                withInMemoryIndexerRunner $ \h runner -> do
                    runScript h [provenanceFirstStep]
                    runTransaction runner $
                        insert
                            AddressIndex
                            (AddrKey (addrOf 0x01) (tx 0x01))
                            (TxOut "corrupted")
                    applyAtSlot
                        h
                        (SlotNo 2)
                        (BlockHash (hashOf 2))
                        [UtxoSpend (tx 0x01)]
                    r <- assetUtxos h (polId p1Bytes) (name "tok")
                    r `shouldBe` Left AssetIndexAbsent

            it "orphaned asset row answers AssetIndexInconsistent" $
                withInMemoryIndexerRunner $ \h runner -> do
                    runScript h [provenanceFirstStep]
                    -- Remove the live TxIn data, leaving an asset row
                    -- behind: the read must degrade to the explicit
                    -- inconsistency, never a partial list.
                    runTransaction runner $ delete TxInCol (tx 0x01)
                    assetUtxos h (polId p1Bytes) (name "tok")
                        `shouldReturn` Left (AssetIndexInconsistent (tx 0x01))

            it "asset row without stored bytes answers AssetIndexInconsistent" $
                withInMemoryIndexerRunner $ \h runner -> do
                    runScript h [provenanceFirstStep]
                    runTransaction runner $
                        delete AddressIndex (AddrKey (addrOf 0x01) (tx 0x01))
                    assetUtxos h (polId p1Bytes) (name "tok")
                        `shouldReturn` Left (AssetIndexInconsistent (tx 0x01))

            it "asset row without observation answers AssetIndexInconsistent" $
                withInMemoryIndexerRunner $ \h runner -> do
                    runScript h [provenanceFirstStep]
                    runTransaction runner $ delete ObservationCol (tx 0x01)
                    assetUtxos h (polId p1Bytes) (name "tok")
                        `shouldReturn` Left (AssetIndexInconsistent (tx 0x01))

-- * Script model

data ScriptOp
    = Create TxIn Address Produced
    | Spend TxIn

data Step = Step
    { stSlot :: Word64
    , stHash :: ByteString
    , stOps :: [ScriptOp]
    }

data Action
    = Apply Step
    | Rollback Word64

{- | A ledger-built output plus the asset list read back from the
ledger's own decoding of its stored bytes — the producer's values,
never typed expectations.
-}
data Produced = Produced
    { pTxOut :: TxOut
    , pAssets :: [(ByteString, ByteString, Word64)]
    }

data ModelOut = ModelOut
    { mBytes :: TxOut
    , mAssets :: [(ByteString, ByteString, Word64)]
    , mCreated :: (Word64, ByteString)
    }

type ModelState = Map TxIn ModelOut

{- | Serial model replay. @applied@ maps every applied slot to its
block hash and resulting state; a rollback drops slots above the
target and the state becomes the newest remaining slot's state (the
rollback contract). The sequence records the @(point, state)@ after
every action.
-}
runModel :: [Action] -> [((Word64, ByteString), ModelState)]
runModel = go Map.empty []
  where
    go _applied acc [] = reverse acc
    go applied acc (Apply Step{stSlot, stHash, stOps} : rest) =
        let current = currentState applied
            st =
                foldl
                    (flip (modelOp stSlot stHash))
                    current
                    stOps
            applied' = Map.insert stSlot (stHash, st) applied
         in go applied' (((stSlot, stHash), st) : acc) rest
    go applied acc (Rollback target : rest) =
        let kept =
                Map.filterWithKey
                    (\k _ -> k <= target)
                    applied
            (point, st) = case Map.lookupMax kept of
                Nothing -> ((0, BS.empty), Map.empty)
                Just (slot, (hash, state)) -> ((slot, hash), state)
         in go kept ((point, st) : acc) rest

currentState :: Map Word64 (ByteString, ModelState) -> ModelState
currentState applied = case Map.lookupMax applied of
    Nothing -> Map.empty
    Just (_, (_, st)) -> st

modelOp :: Word64 -> ByteString -> ScriptOp -> ModelState -> ModelState
modelOp slot hash op st = case op of
    Create t _ p ->
        Map.insert
            t
            ( ModelOut
                { mBytes = pTxOut p
                , mAssets = pAssets p
                , mCreated = (slot, hash)
                }
            )
            st
    Spend t -> Map.delete t st

-- | Expected matches of one asset in a model state, ascending TxIn.
modelMatches ::
    ByteString -> ByteString -> ModelState -> [AssetMatch]
modelMatches policy asset st =
    sortOn
        amTxIn
        [ AssetMatch
            { amTxIn = t
            , amTxOut = mBytes m
            , amQuantity = q
            , amCreatedSlot = SlotNo s
            , amCreatedBlockHash = BlockHash h
            }
        | (t, m) <- Map.toList st
        , (p, n, q) <- mAssets m
        , p == policy
        , n == asset
        , (s, h) <- [mCreated m]
        ]

-- * Driving the indexer

applyStep :: IndexerHandle -> Step -> IO ()
applyStep h Step{stSlot, stHash, stOps} =
    applyAtSlot
        h
        (SlotNo stSlot)
        (BlockHash stHash)
        (map toOp stOps)
  where
    toOp (Create t a p) = UtxoCreate t a (pTxOut p)
    toOp (Spend t) = UtxoSpend t

runScript :: IndexerHandle -> [Action] -> IO ()
runScript h = mapM_ act
  where
    act (Apply s) = applyStep h s
    act (Rollback t) = rollbackTo h (SlotNo t)

{- | The concurrency writer: like 'runScript' but with a small delay
per step so readers observably overlap the mutation window.
-}
runScriptDelayed :: IndexerHandle -> [Action] -> IO ()
runScriptDelayed h = mapM_ act
  where
    act a = do
        threadDelay 2000
        case a of
            Apply s -> applyStep h s
            Rollback t -> rollbackTo h (SlotNo t)

{- | Run a script and, after every action, assert the typed read of
every listed asset equals the model's state at the model's point.
-}
runScriptAndCheck ::
    IndexerHandle ->
    [Action] ->
    [(ByteString, ByteString)] ->
    IO ()
runScriptAndCheck h actions assets =
    forM_ (zip actions (runModel actions)) $ \(act, (point, st)) -> do
        case act of
            Apply s -> applyStep h s
            Rollback t -> rollbackTo h (SlotNo t)
        forM_ assets $ \(p, n) ->
            assetUtxos h (polId p) (name n)
                `shouldReturnSnapshot` (point, modelMatches p n st)

shouldReturnSnapshot ::
    IO (Either AssetQueryUnavailable AssetSnapshot) ->
    ((Word64, ByteString), [AssetMatch]) ->
    IO ()
shouldReturnSnapshot action ((slot, hash), expected) = do
    r <- action
    case r of
        Left e -> error (show e)
        Right AssetSnapshot{asPoint, asMatches} -> do
            asPoint `shouldBe` (SlotNo slot, BlockHash hash)
            asMatches `shouldBe` expected

collectResults ::
    IndexerHandle ->
    [Action] ->
    IO [Either AssetQueryUnavailable AssetSnapshot]
collectResults h actions = do
    ref <- newIORef []
    forM_ actions $ \act -> do
        case act of
            Apply s -> applyStep h s
            Rollback t -> rollbackTo h (SlotNo t)
        r <- assetUtxos h (polId p1Bytes) (name "tok")
        append ref r
    readIORef ref

append :: IORef [a] -> a -> IO ()
append ref x = do
    xs <- readIORef ref
    writeIORef ref (xs ++ [x])

{- | The reader loop for the concurrency leg: every snapshot must
equal the model state recorded at its point; @NoIndexedPoint@ is a
permitted answer (the store has no following row yet), any other
unavailability is not. Counts reads, reads overlapping the writer,
and the distinct points seen.
-}
reader ::
    IndexerHandle ->
    Map (SlotNo, BlockHash) [AssetMatch] ->
    IORef Bool ->
    IORef Int ->
    IORef Int ->
    IORef (Set (SlotNo, BlockHash)) ->
    IO ()
reader h recorded done readsTotal readsDuringWriter pointsSeen = loop
  where
    loop = do
        isDone <- readIORef done
        unless isDone $ do
            modifyIORef' readsTotal (+ 1)
            wasDuring <- not <$> readIORef done
            when wasDuring $ modifyIORef' readsDuringWriter (+ 1)
            r <- assetUtxos h (polId p1Bytes) (name "tok")
            case r of
                Right AssetSnapshot{asPoint, asMatches} -> do
                    modifyIORef' pointsSeen (Set.insert asPoint)
                    case Map.lookup asPoint recorded of
                        Nothing ->
                            error ("unknown point " <> show asPoint)
                        Just expected ->
                            asMatches `shouldBe` expected
                Left NoIndexedPoint -> pure ()
                Left e -> error (show e)
            loop

{- | Non-degeneracy witness: every listed asset really holds a
live output in at least one model state, so a producer that
silently emitted no assets cannot pass the suite.
-}
nonDegenerateWitness ::
    [Action] -> [(ByteString, ByteString)] -> IO ()
nonDegenerateWitness actions assets =
    let states = map snd (runModel actions)
     in forM_ assets $ \(p, n) ->
            not (all (null . modelMatches p n) states)
                `shouldSatisfy` id

{- | Multi-holder witness: the primary asset reaches more than one
simultaneous live holder in some model state.
-}
multiHolderWitness :: [Action] -> IO ()
multiHolderWitness actions =
    let states = map snd (runModel actions)
     in maximum
            (0 : map (length . modelMatches p1Bytes "tok") states)
            `shouldSatisfy` (> 1)

recordedStates :: [Action] -> Map (SlotNo, BlockHash) [AssetMatch]
recordedStates actions =
    Map.fromList
        [ ((SlotNo s, BlockHash h), modelMatches p1Bytes "tok" st)
        | ((s, h), st) <- runModel actions
        ]

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

ledgerPolicy :: ByteString -> Mary.PolicyID
ledgerPolicy b =
    Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort b)))

{- | Build an output holding the given assets and read its asset list
back from the ledger's own decoding of the stored bytes.
-}
produced :: [(ByteString, ByteString, Word64)] -> Produced
produced assets = Produced{pTxOut = TxOut bytes, pAssets = expected}
  where
    v =
        Mary.valueFromList
            (Coin 100)
            [ (ledgerPolicy p, Mary.AssetName (SBS.toShort n), toInteger q)
            | (p, n, q) <- assets
            ]
    out = mkBasicTxOut @ConwayEra ledgerAddr v
    bytes = serialize' (Ledger.eraProtVerLow @ConwayEra) out
    expected =
        case decodeFullDecoder
                (Ledger.eraProtVerLow @ConwayEra)
                "txout"
                decCBOR
                (BSL.fromStrict bytes) ::
                Either DecoderError (Ledger.TxOut ConwayEra) of
            Left e -> error (show e)
            Right out' ->
                let Mary.MaryValue _ ma = out' ^. Ledger.valueTxOutL
                 in [ (SBS.fromShort p, SBS.fromShort n, fromInteger q)
                    | ( Mary.PolicyID (ScriptHash (UnsafeHash p))
                        , Mary.AssetName n
                        , q
                        ) <-
                        Mary.flattenMultiAsset ma
                    , q > 0
                    ]

-- * Fixtures

p1Bytes, p2Bytes :: ByteString
p1Bytes = BS.replicate 28 0x11
p2Bytes = BS.replicate 28 0x22

polId :: ByteString -> PolicyId
polId b = fromMaybe (error "bad policy") (mkPolicyId b)

name :: ByteString -> AssetName
name b = fromMaybe (error "bad asset name") (mkAssetName b)

tx :: Word8 -> TxIn
tx b = TxIn (BS.replicate 32 b) 0

addrOf :: Word8 -> Address
addrOf b = Address (BS.replicate 29 b)

{- | The address a create used, recovered from the TxIn id's first
byte (the fixtures pair @tx b@ with @addrOf b@).
-}
addrFor :: TxIn -> Address
addrFor (TxIn tid _) = case BS.uncons tid of
    Just (b, _) -> Address (BS.replicate 29 b)
    Nothing -> Address BS.empty

hashOf :: Word64 -> ByteString
hashOf n = BS.replicate 32 (fromIntegral (n `mod` 256))

lastSlot :: Word64
lastSlot = 3

-- | (policy, name) pairs covered by the maintenance script.
allAssets :: [(ByteString, ByteString)]
allAssets =
    [ (p1Bytes, "tok")
    , (p1Bytes, "")
    , (p2Bytes, "tok")
    , (p1Bytes, "\xF0\x9F")
    , (p1Bytes, BS.replicate 32 0xEE)
    , (p2Bytes, "other")
    ]

maintenanceScript :: [Action]
maintenanceScript =
    [ step
        1
        [ Create (tx 0x01) (addrOf 0x01) (produced [(p1Bytes, "tok", 10)])
        , Create (tx 0x02) (addrOf 0x02) (produced [(p1Bytes, "tok", 20)])
        , Create (tx 0x03) (addrOf 0x03) (produced [(p1Bytes, "tok", 30)])
        ]
    , step
        2
        [ Create
            (tx 0x04)
            (addrOf 0x04)
            ( produced
                [ (p1Bytes, "", 5)
                , (p1Bytes, "\xF0\x9F", 6)
                , (p2Bytes, "tok", 7)
                , (p2Bytes, "other", 8)
                , (p1Bytes, BS.replicate 32 0xEE, 9)
                ]
            )
        ]
    , -- Move: spend one holder, recreate the asset elsewhere.
      step
        3
        [ Spend (tx 0x02)
        , Create (tx 0x05) (addrOf 0x05) (produced [(p1Bytes, "tok", 20)])
        ]
    , -- Split: one holder becomes two.
      step
        4
        [ Spend (tx 0x05)
        , Create (tx 0x06) (addrOf 0x06) (produced [(p1Bytes, "tok", 8)])
        , Create (tx 0x07) (addrOf 0x07) (produced [(p1Bytes, "tok", 12)])
        ]
    , -- Partial spend of the multi-holder set.
      step 5 [Spend (tx 0x03)]
    , -- Burn: every remaining holder of the asset is spent.
      step 6 [Spend (tx 0x06), Spend (tx 0x07), Spend (tx 0x01)]
    , Rollback 5
    , step 7 [Spend (tx 0x03)]
    ]
  where
    step slot ops = Apply Step{stSlot = slot, stHash = hashOf slot, stOps = ops}

holdersScript :: [Action]
holdersScript =
    [ step
        1
        [ Create (tx 0x21) (addrOf 0x21) (produced [(p1Bytes, "tok", 1)])
        , Create (tx 0x22) (addrOf 0x22) (produced [(p1Bytes, "tok", 2)])
        , Create (tx 0x23) (addrOf 0x23) (produced [(p1Bytes, "tok", 3)])
        ]
    , step 2 [Create (tx 0x24) (addrOf 0x24) (produced [(p2Bytes, "tok", 9)])]
    , step lastSlot [Spend (tx 0x22)]
    ]
  where
    step slot ops = Apply Step{stSlot = slot, stHash = hashOf slot, stOps = ops}

expectedMatches :: [AssetMatch]
expectedMatches =
    modelMatches p1Bytes "tok" (newestModelState holdersScript)

provenanceScript :: [Action]
provenanceScript =
    [ step 1 [Create (tx 0x01) (addrOf 0x01) (produced [(p1Bytes, "tok", 10)])]
    , step 3 [Spend (tx 0x01)]
    , Rollback 1
    , step 4 [Create (tx 0x02) (addrOf 0x02) (produced [(p1Bytes, "tok", 5)])]
    ]
  where
    step slot ops = Apply Step{stSlot = slot, stHash = hashOf slot, stOps = ops}

parityScript :: [Action]
parityScript = maintenanceScript

{- | Replace a live TxIn with a different-asset output, spend it,
then roll back past the spend (restoring the replacement) and past
the replacement (restoring the original with its original creation
point).
-}
replacementScript :: [Action]
replacementScript =
    [ step 1 [Create (tx 0x51) (addrOf 0x51) (produced [(p1Bytes, "old", 10)])]
    , step
        2
        [Create (tx 0x51) (addrOf 0x51) (produced [(p1Bytes, "new", 20)])]
    , step 3 [Spend (tx 0x51)]
    , Rollback 2
    , Rollback 1
    ]
  where
    step slot ops = Apply Step{stSlot = slot, stHash = hashOf slot, stOps = ops}

-- | Both asset answers after every step of the replacement script.
collectReplacementResults ::
    IndexerHandle ->
    IO
        [ ( Either AssetQueryUnavailable AssetSnapshot
          , Either AssetQueryUnavailable AssetSnapshot
          )
        ]
collectReplacementResults h = do
    ref <- newIORef []
    forM_ (zip (runModel replacementScript) replacementScript) $ \((_, _st), act) -> do
        case act of
            Apply s -> applyStep h s
            Rollback t -> rollbackTo h (SlotNo t)
        rOld <- assetUtxos h (polId p1Bytes) (name "old")
        rNew <- assetUtxos h (polId p1Bytes) (name "new")
        append ref (rOld, rNew)
    readIORef ref

concurrencyScript :: [Action]
concurrencyScript =
    [ hold 1 [(0x31, 10)]
    , hold 2 [(0x32, 20)]
    , hold 3 [(0x33, 30)]
    , Rollback 2
    , hold 4 [(0x34, 40)]
    , hold 5 [(0x35, 50)]
    , Rollback 3
    , hold 6 [(0x36, 60)]
    ]
  where
    hold slot holds =
        Apply
            Step
                { stSlot = slot
                , stHash = hashOf slot
                , stOps =
                    [ Create
                        (tx b)
                        (addrOf b)
                        (produced [(p1Bytes, "tok", q)])
                    | (b, q) <- holds
                    ]
                }

-- * Pre-change store seeding

preChangeTxIn :: TxIn
preChangeTxIn = tx 0x77

preChangeAddr :: Address
preChangeAddr = addrOf 0x77

preChangeOut :: TxOut
preChangeOut = pTxOut (produced [(p1Bytes, "tok", 5)])

preChangeFamilies :: [(String, Config)]
preChangeFamilies =
    [ ("utxo-indexer.txin", def)
    , ("utxo-indexer.address", def)
    , ("utxo-indexer.observation", def)
    , ("utxo-indexer.rollback", def)
    ]

-- | The full six-family list, in the GADT pairing order.
fullFamilies :: [(String, Config)]
fullFamilies =
    preChangeFamilies
        ++ [ ("utxo-indexer.asset", def)
           , ("utxo-indexer.meta", def)
           ]

{- | Create a store with the pre-change column-family set and populate
it through the pre-change codecs, as the old binary would have.
-}
seedPreChangeStore :: FilePath -> IO ()
seedPreChangeStore path =
    withDBCF path def{createIfMissing = True} preChangeFamilies $ \rdb -> do
        let database =
                mkRocksDBDatabase
                    rdb
                    (mkColumns (columnFamilies rdb) preChangeCodecs)
        runner <- newRunTransaction database
        runTransaction runner $ do
            insert TxInCol preChangeTxIn preChangeAddr
            insert
                AddressIndex
                (AddrKey preChangeAddr preChangeTxIn)
                preChangeOut
            insert
                ObservationCol
                preChangeTxIn
                (SlotNo 7, BlockHash (hashOf 7))
            insert
                RollbackCol
                (SlotNo 7)
                RollbackPoint
                    { rpInverses = [[]]
                    , rpMeta = Just (BlockHash (hashOf 7))
                    }

preChangeCodecs :: DMap Cols Codecs
preChangeCodecs =
    fromList
        [ TxInCol :=> txInColCodecs
        , AddressIndex :=> addressIndexCodecs
        , ObservationCol :=> observationColCodecs
        , RollbackCol :=> rollbackCodecs
        ]

-- * Misc helpers

{- | The model state after the last action of a script (empty for
the empty script).
-}
newestModelState :: [Action] -> ModelState
newestModelState actions = case reverse (runModel actions) of
    ((_, st) : _) -> st
    [] -> Map.empty

-- | The first step of the provenance script (the create at slot 1).
provenanceFirstStep :: Action
provenanceFirstStep = case provenanceScript of
    (a : _) -> a
    [] -> error "provenance script is empty"

isConflictAt1 :: Either ApplyConflict () -> Bool
isConflictAt1 (Left ApplyConflict{acSlot = SlotNo 1}) = True
isConflictAt1 _ = False
