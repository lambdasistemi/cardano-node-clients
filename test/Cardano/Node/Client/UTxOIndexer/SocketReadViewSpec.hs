{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.SocketReadViewSpec
Description : Atomic socket batches against an independent ledger history
License     : Apache-2.0

The selected guard runs on both real backends over AF_UNIX. A wrapper only
materializes a genuine view and gates a writer; it never supplies answers.
Handshake/unknown-point failures throw exceptions, which the fault runner
classifies as setup failures. Contents equality is the atomicity assertion.
-}
module Cardano.Node.Client.UTxOIndexer.SocketReadViewSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Columns (Cols (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle (..), ReadQuery (..), UtxoOp (..), withRocksDBIndexer)
import Cardano.Node.Client.UTxOIndexer.SocketViewFixture
import Cardano.Node.Client.UTxOIndexer.StoreFixture (seedPreChangeStore)
import Cardano.Node.Client.UTxOIndexer.Types (AddrKey (..), Address (..), AssetName (..), PolicyId (..), SlotNo (..), TxOut (..))
import Cardano.Node.Client.UTxOIndexer.WireClient (BatchAnswer (..), BatchResult (..), batchAnswer, decoded, encodeLine, hex, objectWithKeys, requestLine, textField)
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (evaluate)
import Control.Monad (forM_, unless, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Database.KV.Transaction (delete, insert, runTransaction)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

-- | Batch schema, proof, refusal and inherited exception observations.
spec :: Spec
spec = describe "utxo-indexer socket read view" $ do
    it "serves the missing mixed request with ordered duplicate-preserving contents" $
        forM_ backends $ \backend -> withBackend backend $ \h _ -> do
            seed h
            withServer h $ \sock -> do
                raw <- requestLine sock (batchLine queries)
                putStrLn ("MIXED-REQUEST " <> show (batchLine queries) <> " ACTUAL " <> show raw)
                batchAnswer raw `shouldBe` Right (uncurry (expected queries) firstState)

    it "every answer equals independent state at the reported point across a controlled advance" $ do
        mismatches <- newIORef []
        forM_ backends $ \backend -> forM_ [1, 2, 3, 4, 5] $ \step -> withBackend backend $ \h _ -> do
            unless (fixedOutputDomain script) (fail "setup: reference reused with different output")
            let states = history script
                (p, before) = states !! (step - 1)
                (q, after) = states !! (if step == 2 then 3 else step)
                model = Map.fromList states
                request = batchLine queries
            mapM_ (drive h) (take step script)
            unless (Map.size before > 1 && Map.size after > 1 && p /= q && expected queries p before /= expected queries p after) $
                fail "setup: advance does not discriminate contents"
            gate <- newEmptyMVar
            ack <- newEmptyMVar
            first <- newIORef True
            captured <- newIORef Nothing
            let readThenAdvance qs = do
                    answer <- readView h qs
                    _ <- evaluate (length (show answer))
                    isFirst <- atomicModifyIORef' first (False,)
                    when isFirst $ do
                        writeIORef captured (Just (qs, answer))
                        putMVar gate ()
                        bounded "writer acknowledgement" (takeMVar ack)
                    pure answer
                writer = do
                    bounded "first materialized view" (takeMVar gate)
                    mapM_ (drive h) (take (if step == 2 then 2 else 1) (drop step script))
                    -- A real read proves the acknowledged commit at Q.
                    actual <- readView h queries
                    unless (actual == Right (expectedView queries q after)) $
                        fail "setup: writer did not commit the independently modeled Q"
                    putMVar ack ()
            withAsync writer $ \writing -> withServer h{readView = readThenAdvance} $ \sock -> do
                raw <- bounded "socket response" (requestLine sock request)
                answer <- case batchAnswer raw of
                    Left why -> expectationFailure (why <> "; actual response " <> show raw) >> fail "unreachable"
                    Right v -> pure v
                bounded "writer completion" (wait writing)
                materialized <- readIORef captured
                case materialized of
                    Just (qs, Right view) ->
                        view `shouldBe` expectedView qs p before
                    _ -> fail "setup: no materialized view captured"
                state <-
                    maybe (fail "setup: unknown reported point") pure $
                        Map.lookup (batchPoint answer) (Map.mapKeys wirePoint model)
                putStrLn
                    ( "SOCKET-VIEW backend="
                        <> backend
                        <> " step="
                        <> show step
                        <> " request="
                        <> show request
                        <> " queries="
                        <> show (NE.length queries)
                        <> " captured="
                        <> show (wirePoint p)
                        <> " committed="
                        <> show (wirePoint q)
                        <> " writer_ack=yes members_at_P="
                        <> show (Map.size before)
                        <> " members_at_Q="
                        <> show (Map.size after)
                        <> " reported="
                        <> show (batchPoint answer)
                    )
                -- Compare all members, bytes, exact quantities, creation point
                -- and ledger datum facts, rather than call counts or point-only.
                let oracle = expected queries (pointOf (batchPoint answer) model) state
                    differing = [(i, want, got) | (i, (want, got)) <- zip [0 :: Int ..] (zip (batchResults oracle) (batchResults answer)), want /= got]
                unless (answer == oracle) $
                    modifyIORef' mismatches ((backend, step, "expected/actual content mismatch: " <> show (take 1 differing) <> "; cardinality " <> show (length (batchResults oracle), length (batchResults answer))) :)
        -- Collect every backend/transition before rejecting mixed contents,
        -- so a fault cannot prevent the RocksDB witness from executing.
        readIORef mismatches `shouldReturn` []

    forM_ backends $ \backend -> describe backend $ do
        it "matches every history state and homogeneous/singleton batches" $
            withBackend backend $ \h _ -> withServer h $ \sock -> do
                fixedOutputDomain script `shouldBe` True
                fixedOutputDomain [Apply 1 (blockHash 1) [Create (tx 1) (produced 0xA1 7 0)], Apply 2 (blockHash 2) [Create (tx 1) (produced 0xB2 8 1)]] `shouldBe` False
                forM_ (zip script (history script)) $ \(action, (p, st)) -> do
                    drive h action
                    forM_ [queries, AddressQuery addrA :| [AddressQuery addrB, AddressQuery addrA], AssetQuery policyA (AssetName "tok") :| [AssetQuery policyB (AssetName "tok")], AddressQuery addrA :| []] $ \qs -> do
                        raw <- requestLine sock (batchLine qs)
                        batchAnswer raw `shouldBe` Right (expected qs p st)

        it "validates the whole batch before storage including an invalid later member" $
            withBackend backend $ \h _ -> do
                seed h
                readCount <- newIORef (0 :: Int)
                let tracked qs = atomicModifyIORef' readCount (\n -> (n + 1, ())) >> readView h qs
                withServer h{readView = tracked} $ \sock -> do
                    forM_ invalidLines $ \(position, line) -> do
                        raw <- requestLine sock line
                        detail <- invalidDetail raw
                        forM_ position $ \i -> detail `shouldSatisfy` Text.isInfixOf (Text.pack (show i))
                    readIORef readCount `shouldReturn` 0
                    -- Raw-byte addresses retain empty and uppercase acceptance.
                    forM_ ["", Text.toUpper (hex (unAddress addrA))] $ \a -> do
                        let qs = AddressQuery (Address (if Text.null a then "" else unAddress addrA)) :| []
                        raw <- requestLine sock (encodeLine ["read_view" .= [Aeson.object ["utxos_at" .= a]]])
                        batchAnswer raw `shouldBe` Right (uncurry (expected qs) firstState)
                    let upperQuery = Aeson.object ["utxos_with_asset" .= Aeson.object ["policy_id" .= Text.toUpper (hex (unPolicyId policyA)), "asset_name" .= ("746F6B" :: Text.Text)]]
                    raw <- requestLine sock (encodeLine ["read_view" .= [upperQuery]])
                    batchAnswer raw `shouldBe` Right (uncurry (expected (AssetQuery policyA (AssetName "tok") :| [])) firstState)

        it "forwards no point, absent, rebuilding and incomplete whole-view refusals" $ do
            withBackend backend $ \h runner -> do
                refused h "no_indexed_point"
                follower <- newFollowerState h True
                _ <- processFollowerBlock h follower 2 False (SlotNo 1) (blockHash 1) []
                refused h "no_indexed_point"
                seed h
                runTransaction runner $ delete MetaCol "asset-index"
                refused h "absent"
                runTransaction runner $ insert MetaCol "asset-index-rebuild" "in progress"
                refused h "rebuilding"
            withBackend backend $ \h _ -> do
                seed h
                applyAtSlot h (SlotNo 2) (blockHash 2) [UtxoCreate (tx 99) addrB (TxOut "invalid")]
                refused h "absent"
                snapshotAt h addrB >>= (`shouldSatisfy` elem (tx 99, TxOut "invalid"))

        it "refuses mixed views for every inconsistent join and undecodable asset datum" $
            forM_ [0, 1, 2, 3 :: Int] $ \corruption -> withBackend backend $ \h runner -> do
                seed h
                runTransaction runner $ case corruption of
                    0 -> delete TxInCol (tx 0x55)
                    1 -> delete AddressIndex (AddrKey addrA (tx 0x55))
                    2 -> delete ObservationCol (tx 0x55)
                    _ -> insert AddressIndex (AddrKey addrA (tx 0x55)) (TxOut "invalid")
                withServer h $ \sock -> do
                    raw <- requestLine sock (batchLine queries)
                    unavailable raw "inconsistent"

        it "returns available empty matches without confusing them with unavailability" $
            withBackend backend $ \h _ -> do
                seed h
                let qs = AddressQuery (Address "absent") :| [AssetQuery policyA (AssetName "absent")]
                withServer h $ \sock -> do
                    raw <- requestLine sock (batchLine qs)
                    batchAnswer raw `shouldBe` Right (uncurry (expected qs) firstState)

        it "preserves EOF without a response when readView storage throws" $
            withBackend backend $ \h _ -> withServer h{readView = \_ -> fail "injected storage exception"} $ \sock ->
                bounded "exception EOF" (requestLine sock (batchLine queries)) `shouldReturn` BS.empty

    it "refuses address-only views over a degraded pre-change store" $
        withSystemTempDirectory "socket-view-degraded" $ \dir -> do
            let p = produced 0xA1 7 0
                point = (SlotNo 1, blockHash 1)
            seedPreChangeStore (dir <> "/db") [(tx 1, outAddress p, outBytes p, point)] [point]
            withRocksDBIndexer (dir <> "/db") $ \h -> refused h "absent"

    it "rejects extra response keys, wrong row types, datum keys and nonintegral slots" $ do
        let p = Aeson.object ["slot" .= (1 :: Int), "blockHash" .= ("aa" :: Text.Text)]
            line point rows = encodeLine ["point" .= point, "results" .= rows] <> "\n"
            good = line p [Aeson.object ["utxos_at" .= ([] :: [Aeson.Value])]]
            asset datum =
                Aeson.object
                    [ "utxos_with_asset"
                        .= [ Aeson.object
                                ["txin" .= ("aa#0" :: Text.Text), "txout" .= ("aa" :: Text.Text), "quantity" .= ("3" :: Text.Text), "created" .= p, "datum" .= datum]
                           ]
                    ]
        batchAnswer good `shouldBe` Right (BatchAnswer (1, "aa") [AddressRows []])
        forM_
            [ BS.init good
            , good <> "\n"
            , line p ([] :: [Aeson.Value])
            , line (Aeson.object ["slot" .= (1.5 :: Double), "blockHash" .= ("aa" :: Text.Text)]) [Aeson.object ["utxos_at" .= ([] :: [Aeson.Value])]]
            , encodeLine ["point" .= p, "results" .= ([] :: [Aeson.Value]), "extra" .= True] <> "\n"
            , line p [Aeson.object ["utxos_at" .= True]]
            , line p [Aeson.object ["utxos_at" .= ([] :: [Aeson.Value]), "extra" .= True]]
            , line p [asset (Aeson.object ["kind" .= ("none" :: Text.Text), "hash" .= ("aa" :: Text.Text)])]
            , line p [asset (Aeson.object ["kind" .= ("hash" :: Text.Text), "hash" .= True])]
            ]
            $ \bad ->
                batchAnswer bad `shouldSatisfy` either (const True) (const False)

-- Setup failures must not become KILLED through an expectation assertion.
bounded :: String -> IO a -> IO a
bounded label action = timeout 10_000_000 action >>= maybe (fail ("setup timeout: " <> label)) pure

pointOf :: (Integer, Text.Text) -> Map.Map Point State -> Point
pointOf wire model = case [p | p <- Map.keys model, wirePoint p == wire] of
    [p] -> p
    _ -> error "setup: unknown point"

refused :: IndexerHandle -> Text.Text -> IO ()
refused h reason = withServer h $ \sock -> forM_ [queries, AddressQuery addrA :| [AddressQuery addrB]] $ \qs -> requestLine sock (batchLine qs) >>= (`unavailable` reason)

unavailable :: ByteString -> Text.Text -> IO ()
unavailable raw reason =
    decoded raw `shouldBe` Right (Aeson.object ["error" .= ("asset_index_unavailable" :: Text.Text), "reason" .= reason])

invalidDetail :: ByteString -> IO Text.Text
invalidDetail raw = either (\why -> expectationFailure (why <> "; actual " <> show raw) >> fail "unreachable") pure $ do
    o <- objectWithKeys ["error", "detail"] =<< decoded raw
    code <- textField "error" o
    unless (code == "invalid_read_view") (Left ("unexpected error " <> show code))
    textField "detail" o

invalidLines :: [(Maybe Int, ByteString)]
invalidLines =
    [(Nothing, encodeLine ["read_view" .= v]) | v <- [Aeson.Null, Aeson.String "x", Aeson.Bool True, Aeson.object [], Aeson.toJSON ([] :: [Aeson.Value])]]
        <> [(Nothing, encodeLine ["read_view" .= [queryValue (NE.head queries)], "extra" .= True])]
        <> [(Just i, encodeLine ["read_view" .= xs]) | bad <- badElements, (i, xs) <- [(0, [bad]), (1, [queryValue (NE.head queries), bad])]]
  where
    badElements =
        [ Aeson.Null
        , Aeson.String "x"
        , Aeson.toJSON (5 :: Int)
        , Aeson.object []
        , Aeson.object ["utxos_at" .= hex (unAddress addrA), "extra" .= True]
        , Aeson.object ["utxos_at" .= hex (unAddress addrA), "utxos_with_asset" .= Aeson.Null]
        , Aeson.object ["utxos_at" .= Aeson.Null]
        , Aeson.object ["utxos_at" .= (7 :: Int)]
        , Aeson.object ["utxos_at" .= ("zz" :: Text.Text)]
        , Aeson.object ["utxos_at" .= ("a" :: Text.Text)]
        ]
            <> [ Aeson.object ["utxos_with_asset" .= v]
               | v <-
                    [ Aeson.Null
                    , Aeson.String "x"
                    , Aeson.object []
                    , Aeson.object ["policy_id" .= hex (unPolicyId policyA)]
                    , Aeson.object ["asset_name" .= ("" :: Text.Text)]
                    , Aeson.object ["policy_id" .= Aeson.Null, "asset_name" .= ("" :: Text.Text)]
                    , Aeson.object ["policy_id" .= hex (unPolicyId policyA), "asset_name" .= True]
                    , Aeson.object ["policy_id" .= hex (unPolicyId policyA), "asset_name" .= ("" :: Text.Text), "extra" .= True]
                    ]
                        <> [ Aeson.object ["policy_id" .= p, "asset_name" .= n]
                           | (p, n) <-
                                [(p, "") | p <- ["", "zz", "a", hex (BS.replicate 27 1), hex (BS.replicate 29 1)]]
                                    <> [(hex (unPolicyId policyA), n) | n <- ["z0", "f", hex (BS.replicate 33 1)]]
                           ]
               ]
