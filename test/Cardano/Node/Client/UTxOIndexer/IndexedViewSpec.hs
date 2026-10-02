{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.IndexedViewSpec
Description : Materialized read views against an independent history model
License     : Apache-2.0

The oracle folds ledger-produced outputs into a pure address/asset history.
It never calls production extraction or reads the store to predict results.
The same model assertion runs on both backends and under the split-snapshot
production fault. Retained views are first traversed after their store closes.
-}
module Cardano.Node.Client.UTxOIndexer.IndexedViewSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.AssetIndexSpec qualified as Fixture
import Cardano.Node.Client.UTxOIndexer.Columns (Cols (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AssetMatch (..),
    AssetQueryUnavailable (..),
    AssetSnapshot (..),
    IndexedView (..),
    IndexerHandle (..),
    ReadQuery (..),
    ReadResult (..),
    UtxoOp (..),
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
    withRocksDBIndexerRunner,
 )
import Cardano.Node.Client.UTxOIndexer.StoreFixture (seedPreChangeStore)
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word64)
import Database.KV.Transaction (RunTransaction (..), delete, insert)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer indexed view" $ do
    forM_ backends $ \backend -> describe backend $ do
        it "preserves query order, duplicates, bytes and creation provenance through rollback" $
            withBackend backend $ \h _ -> do
                fixedOutputDomain script `shouldBe` True
                let states = history script
                Map.size (Map.fromList states) `shouldSatisfy` (> 2)
                maximum (map (length . holders . snd) states) `shouldSatisfy` (> 1)
                forM_ (zip script states) $ \(action, (point, state)) -> do
                    drive h action
                    readView h queries `shouldReturn` Right (expected point state)
                    forM_
                        [ AddressQuery addrA :| [AddressQuery addrB, AddressQuery addrA]
                        , AssetQuery policy1 (AssetName "tok") :| [AssetQuery policy2 (AssetName "tok")]
                        ]
                        $ \batch ->
                            readView h batch `shouldReturn` Right (expectedFor batch point state)
                    -- Independent legacy reads on a quiescent store retain
                    -- the signature, byte identity and asset semantics.
                    forM_ (NE.toList queries) $ \case
                        AddressQuery addr -> snapshotAt h addr `shouldReturn` addresses addr state
                        AssetQuery policy asset ->
                            assetUtxos h policy asset `shouldReturn` Right (AssetSnapshot point (matches policy asset state))

        it "retains a materialized view through mutation and store closure" $ do
            (view, oracle) <- withBackend backend $ \h _ -> do
                drive h firstAction
                view <- readView h queries
                let (point, state) = firstState
                mapM_ (drive h) (drop 1 script)
                pure (view, Right (expected point state))
            -- No traversal before leaving the bracket: catches escaped
            -- cursors, storage callbacks and lazy rereads.
            view `shouldBe` oracle

        it "refuses the entire view on empty, restoration-only, absent and rebuilding states" $
            withBackend backend $ \h runner -> do
                refused h NoIndexedPoint
                st <- newFollowerState h True
                (_, processed) <- processFollowerBlock h st 2 False (SlotNo 1) (hash 1) []
                processed `shouldBe` True
                refused h NoIndexedPoint
                drive h firstAction
                runTransaction runner $ delete MetaCol "asset-index"
                refused h AssetIndexAbsent
                runTransaction runner $ insert MetaCol "asset-index-rebuild" "in progress"
                refused h AssetIndexRebuilding

        it "refuses partial results when any asset join loses live data" $
            forM_ [0, 1, 2 :: Int] $ \missing -> withBackend backend $ \h runner -> do
                drive h firstAction
                runTransaction runner $ case missing of
                    0 -> delete TxInCol (tx 1)
                    1 -> delete AddressIndex (AddrKey addrA (tx 1))
                    _ -> delete ObservationCol (tx 1)
                readView h queries `shouldReturn` Left (AssetIndexInconsistent (tx 1))

        it "refuses address-only reads after extraction removes completeness" $
            withBackend backend $ \h _ -> do
                drive h firstAction
                applyAtSlot h (SlotNo 2) (hash 2) [UtxoCreate (tx 99) addrB (TxOut "invalid")]
                refused h AssetIndexAbsent
                snapshotAt h addrB `shouldReturn` [(tx 99, TxOut "invalid")]

    it "address-only views refuse a degraded store while snapshotAt remains available" $
        withSystemTempDirectory "view-degraded" $ \tmp -> do
            let out = Fixture.pTxOut (output 7)
                point = (SlotNo 1, hash 1)
                path = tmp </> "db"
            seedPreChangeStore path [(tx 1, addrA, out, point)] [point]
            withRocksDBIndexer path $ \h -> do
                refused h AssetIndexAbsent
                snapshotAt h addrA `shouldReturn` [(tx 1, out)]

    -- One full path, one intended example for G08. Both implementations
    -- must run this very assertion; the fault changes production only.
    it "every concurrent view equals the model state at its point on both backends" $
        forM_ backends $ \backend -> withBackend backend $ \h _ -> do
            fixedOutputDomain script `shouldBe` True
            let recorded = Map.fromList (history script)
            Map.size recorded `shouldSatisfy` (> 2)
            done <- newIORef False
            attempts <- newIORef (0 :: Int)
            seen <- newIORef Set.empty
            total <- newIORef (0 :: Int)
            overlapping <- newIORef (0 :: Int)
            drive h firstAction
            let readLoop = do
                    stopped <- readIORef done
                    unless stopped $ do
                        atomicModifyIORef' attempts (\n -> (n + 1, ()))
                        result <- readView h queries
                        case result of
                            Left e -> expectationFailure ("unexpected view refusal: " <> show e)
                            Right view -> do
                                case Map.lookup (ivPoint view) recorded of
                                    Nothing -> expectationFailure ("unknown view point: " <> show (ivPoint view))
                                    Just state -> view `shouldBe` expected (ivPoint view) state
                                atomicModifyIORef' seen (\s -> (Set.insert (ivPoint view) s, ()))
                                atomicModifyIORef' total (\n -> (n + 1, ()))
                                during <- not <$> readIORef done
                                when during $ atomicModifyIORef' overlapping (\n -> (n + 1, ()))
                        threadDelay 50
                        readLoop
                writer = forM_ (drop 1 script) $ \action -> do
                    before <- readIORef attempts
                    awaitAttempt attempts before (2000 :: Int)
                    threadDelay 2000
                    drive h action
                finish = writeIORef done True
            withAsync readLoop $ \r1 -> withAsync readLoop $ \r2 -> do
                writer `finally` finish
                wait r1
                wait r2
            readIORef total >>= (`shouldSatisfy` (>= 4))
            readIORef overlapping >>= (`shouldSatisfy` (>= 2))
            readIORef seen >>= (\points -> Set.size points `shouldSatisfy` (> 1))

backends :: [String]
backends = ["in-memory", "RocksDB"]

withBackend :: String -> (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) -> IO a
withBackend "in-memory" = withInMemoryIndexerRunner
withBackend _ = \action -> withSystemTempDirectory "indexed-view" $ \tmp ->
    withRocksDBIndexerRunner (tmp </> "db") action

refused :: IndexerHandle -> AssetQueryUnavailable -> IO ()
refused h reason = do
    readView h queries `shouldReturn` Left reason
    readView h (AddressQuery addrA :| [AddressQuery addrB]) `shouldReturn` Left reason

awaitAttempt :: IORef Int -> Int -> Int -> IO ()
awaitAttempt ref before remaining = do
    now <- readIORef ref
    when (now <= before && remaining > 0) $ do
        threadDelay 100
        awaitAttempt ref before (remaining - 1)

data Action = Apply Word64 BlockHash [Change] | Rollback Word64
data Change = Create TxIn Address Fixture.Produced | Spend TxIn
data ModelOut = ModelOut Address Fixture.Produced (SlotNo, BlockHash)
type State = Map TxIn ModelOut
type Point = (SlotNo, BlockHash)

history :: [Action] -> [(Point, State)]
history = go Map.empty
  where
    go _ [] = []
    go applied (action : rest) =
        let next = case action of
                Apply slot bh changes ->
                    let state = maybe Map.empty (snd . snd) (Map.lookupMax applied)
                        update acc (Create t addr out) = Map.insert t (ModelOut addr out (SlotNo slot, bh)) acc
                        update acc (Spend t) = Map.delete t acc
                     in Map.insert slot (bh, foldl update state changes) applied
                Rollback slot -> Map.filterWithKey (\s _ -> s <= slot) applied
            current = case Map.lookupMax next of
                Nothing -> error "view script rolls behind its first point"
                Just (slot, (bh, state)) -> ((SlotNo slot, bh), state)
         in current : go next rest

{- | Precondition of the script generator and model: a TxIn commits to
one fixed output/address on every fork. Reject fixtures that re-create it
with different bytes; moves use a spend and a new TxIn. A-002 restricts
the domain without changing the address, asset or provenance oracle.
-}
fixedOutputDomain :: [Action] -> Bool
fixedOutputDomain actions = all sameOutput (Map.elems creations)
  where
    creations =
        Map.fromListWith
            (<>)
            [ (t, [(addr, Fixture.pTxOut out)])
            | Apply _ _ changes <- actions
            , Create t addr out <- changes
            ]
    sameOutput [] = False
    sameOutput (out : rest) = all (== out) rest

drive :: IndexerHandle -> Action -> IO ()
drive h (Rollback slot) = rollbackTo h (SlotNo slot)
drive h (Apply slot bh changes) = applyAtSlot h (SlotNo slot) bh (map toOp changes)
  where
    toOp (Create t addr out) = UtxoCreate t addr (Fixture.pTxOut out)
    toOp (Spend t) = UtxoSpend t

expected :: Point -> State -> IndexedView
expected = expectedFor queries

expectedFor :: NonEmpty ReadQuery -> Point -> State -> IndexedView
expectedFor batch point state = IndexedView point (fmap answer batch)
  where
    answer (AddressQuery addr) = AddressResult (addresses addr state)
    answer (AssetQuery policy asset) = AssetResult (matches policy asset state)

addresses :: Address -> State -> [(TxIn, TxOut)]
addresses addr state =
    [(t, Fixture.pTxOut out) | (t, ModelOut a out _) <- Map.toAscList state, a == addr]

matches :: PolicyId -> AssetName -> State -> [AssetMatch]
matches (PolicyId policy) (AssetName asset) state =
    [ AssetMatch t (Fixture.pTxOut out) q slot bh
    | (t, ModelOut _ out (slot, bh)) <- Map.toAscList state
    , (p, n, q) <- Fixture.pAssets out
    , p == policy
    , n == asset
    ]

holders :: State -> [AssetMatch]
holders = matches policy1 (AssetName "tok")

queries :: NonEmpty ReadQuery
queries =
    AddressQuery addrA
        :| [ AssetQuery policy1 (AssetName "tok")
           , AddressQuery addrB
           , AssetQuery policy2 (AssetName "tok")
           , AssetQuery policy1 (AssetName "")
           , AddressQuery addrA
           , AssetQuery policy1 (AssetName "tok")
           , AssetQuery policy1 (AssetName "\xF0\x9F")
           , AssetQuery policy1 (AssetName (BS.replicate 32 0xEE))
           , AddressQuery (Address "absent")
           , AssetQuery policy2 (AssetName "absent")
           ]

addrA, addrB :: Address
addrA = Address (BS.replicate 29 1)
addrB = Address (BS.replicate 29 2)

policy1, policy2 :: PolicyId
policy1 = PolicyId (BS.replicate 28 1)
policy2 = PolicyId (BS.replicate 28 2)

output :: Word64 -> Fixture.Produced
output q =
    Fixture.produced
        [ (unPolicyId policy1, "tok", q)
        , (unPolicyId policy2, "tok", q + 1)
        , (unPolicyId policy1, "", 2)
        , (unPolicyId policy1, "\xF0\x9F", 3)
        , (unPolicyId policy1, BS.replicate 32 0xEE, 4)
        ]

tx :: Word64 -> TxIn
tx n = TxIn (BS.replicate 32 (fromIntegral n)) 0

hash :: Word64 -> BlockHash
hash n = BlockHash (BS.replicate 32 (fromIntegral n))

script :: [Action]
script =
    [ Apply 1 (hash 1) [Create (tx 2) addrA (output 20), Create (tx 1) addrA (output 10)]
    , Apply 2 (hash 2) [Spend (tx 1), Create (tx 3) addrB (output 10)]
    , Apply 3 (hash 3) [Create (tx 2) addrA (output 20), Spend (tx 3)]
    , Rollback 2
    , Rollback 1
    , Apply 2 (hash 12) [Spend (tx 2), Create (tx 4) addrB (output 7), Create (tx 5) addrA (output 3)]
    , Apply 4 (hash 4) [Spend (tx 1), Spend (tx 4), Spend (tx 5)]
    , Rollback 2
    , Apply 5 (hash 5) [Create (tx 6) addrB (output 44)]
    ]

firstAction :: Action
firstAction = case script of
    action : _ -> action
    [] -> error "view script must be nonempty"

firstState :: (Point, State)
firstState = case history script of
    state : _ -> state
    [] -> error "view history must be nonempty"
