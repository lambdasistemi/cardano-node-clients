{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.AssetRestartSpec
Description : utxos_with_asset across daemon restart and the store upgrade
License     : Apache-2.0

Boots a real @cardano-node@ devnet and runs the @utxo-indexer@ daemon
on one RocksDB @--db-path@ five times in a row, stopping it between
runs:

1. against the node: a mint creates several holders of the queried
   token, and the daemon's answer for each asset is recorded;
2. against a socket where no node listens, so only the store can
   answer: the answers equal the recorded ones;
3. against the node again: once ready, the answers equal the recorded
   ones, and a transaction submitted after the restart changes them
   exactly as the chain did;
4. against the node, on a store reduced to the four column families
   that predate the asset index (the raw rows of the daemon's own
   store, copied): without the upgrade request the asset query
   answers @absent@, @utxos_at@ and @await@ answer as before, @ready@
   turns true, and the store keeps four families;
5. against the node with the upgrade request: the asset query answers
   @rebuilding@ until the index is complete, then the holders the
   chain has, and a transaction after the upgrade changes the answer
   exactly as the chain did.

Expected holders come from the node's ledger view of the transactions
the test submits, or from the daemon's own earlier answers; none is a
typed literal. Answer mismatches are collected and reported together
at the end; chain-side failures stop the test at once.
-}
module Cardano.Node.Client.E2E.AssetRestartSpec (spec) where

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api (addrTxOutL)
import Cardano.Ledger.Plutus.Data (Datum (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.AssetQuerySpec (
    Asset (..),
    Ctx (..),
    View,
    assetBytes,
    assetTx,
    coinIn,
    compareAsset,
    fee,
    holderA,
    holderB,
    holderKeyA,
    holdersOf,
    mintTxFrom,
    nodeView,
    out,
    quantityOf,
    queriedAssets,
    requireCount,
    requireRunning,
    step,
    tokenA,
    waitForFile,
    waitReady,
    withNodeClient,
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisAddr,
    genesisDir,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    Answer (..),
    Match (..),
    askAsset,
    assetLine,
    awaitPoint,
    requestLine,
    successAnswer,
    utxosAt,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (
    SomeException,
    displayException,
    handle,
    throwIO,
    try,
 )
import Control.Monad (forM, forM_, unless, when)
import Control.Tracer (nullTracer)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Default.Class (def)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.RocksDB (
    Config (..),
    columnFamilies,
    iterEntry,
    iterFirst,
    iterNext,
    iterValid,
    putCF,
    withDBCF,
    withIterCF,
 )
import Lens.Micro ((^.))
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (
    removeDirectoryRecursive,
    removePathForcibly,
    renameDirectory,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it)

spec :: Spec
spec =
    describe "utxo-indexer daemon: asset index across restart and upgrade on a devnet (E2E)" $
        it
            "keeps its asset answers across restart and upgrades a pre-asset store only on request"
            runRestartE2E

runRestartE2E :: IO ()
runRestartE2E = do
    gDir <- genesisDir
    withCardanoNode gDir $ \nodeSock _ ->
        withSystemTempDirectory "asset-restart-e2e" $ \tmp ->
            withNodeClient nodeSock $ \provider submitter -> do
                mismatches <- newIORef []
                let sock = tmp </> "indexer.sock"
                    db = tmp </> "db"
                    ctx = Ctx sock provider submitter mismatches
                    daemon :: String -> FilePath -> Bool -> IO a -> IO a
                    daemon run relay request = withDaemon run (config relay sock db request)
                    report msg = modifyIORef' mismatches (msg :)

                -- 1. Holders from a transaction this test submits.
                (v1, recorded) <- daemon "first run" nodeSock False $ do
                    waitReady sock 120
                    v1 <- mintStep ctx
                    holdersOf v1 tokenA `requireCount` 2
                    (v1,) <$> answers sock

                -- 2. No node: only the store can answer.
                daemon "restart without a node" (tmp </> "no-node.sock") False $
                    answers sock >>= sameAnswers report "restarted without a node" recorded

                -- 3. Ready again, same holders; a transaction after the restart.
                (v2, afterMove, utxosBefore) <- daemon "restart against the node" nodeSock False $ do
                    waitReady sock 120
                    answers sock >>= sameAnswers report "restarted and ready" recorded
                    v2 <- moveStep ctx v1
                    (v2,,) <$> answers sock <*> holderUtxos sock

                -- 4. A pre-change store without the request.
                toPreChangeStore db
                daemon "pre-change store, no request" nodeSock False $ do
                    waitReady sock 120
                    forM_ queriedAssets $ \asset -> do
                        resp <- requestLine sock (uncurry assetLine (assetBytes asset))
                        when (unavailableReason resp /= Just "absent") $
                            report
                                ( "pre-change store, "
                                    <> assetLabel asset
                                    <> ": answered "
                                    <> show resp
                                    <> " instead of absent"
                                )
                    utxosNow <- holderUtxos sock
                    when (utxosNow /= utxosBefore) $
                        report "pre-change store: utxos_at differs from the full store's"
                    forM_ (concat afterMove) $ \m -> do
                        observed <- awaitPoint sock (mTxIn m) 10
                        when (observed /= mCreated m) $
                            report
                                ( "pre-change store: await "
                                    <> Text.unpack (mTxIn m)
                                    <> " is "
                                    <> show observed
                                    <> ", the asset answer said "
                                    <> show (mCreated m)
                                )
                fourFamilies <- try @SomeException (withDBCF db def preChangeFamilies (\_ -> pure ()))
                either
                    (\e -> report ("pre-change store no longer opens with four families: " <> show e))
                    pure
                    fourFamilies

                -- 5. The upgrade on request.
                daemon "pre-change store, upgrade requested" nodeSock True $ do
                    upgraded <- forM queriedAssets (awaitUpgrade sock 600)
                    sameAnswers report "upgraded" afterMove (map ansMatches upgraded)
                    view <- nodeView provider
                    forM_ queriedAssets (compareAsset ctx "upgraded" view)
                    splitStep ctx v2

                found <- readIORef mismatches
                unless (null found) $
                    expectationFailure (unlines (reverse found))

-- * The transactions

mintStep :: Ctx -> IO View
mintStep ctx = do
    genesis <- queryUTxOs (ctxProvider ctx) genesisAddr
    (gIn, gOut) <- case genesis of
        g : _ -> pure g
        [] -> fail "setup: no genesis UTxO"
    step ctx "mint" Map.empty (mintTxFrom gIn gOut)

-- | Move the token holder of quantity 1 from holder A to holder B.
moveStep :: Ctx -> View -> IO View
moveStep ctx view = do
    t <- holderWith view 1
    c <- coinIn view t
    step ctx "move after restart" view $
        assetTx
            (Set.singleton t)
            [out holderB (c - fee) [(tokenA, 1)] NoDatum]
            mempty
            []
            [holderKeyA]

-- | Split holder A's output of quantity 2 into two of quantity 1.
splitStep :: Ctx -> View -> IO ()
splitStep ctx view = do
    t <- holderWith view 2
    c <- coinIn view t
    let half = (c - fee) `div` 2
    v <-
        step ctx "split after upgrade" view $
            assetTx
                (Set.singleton t)
                [ out holderA half [(tokenA, 1)] NoDatum
                , out holderA (c - fee - half) [(tokenA, 1)] NoDatum
                ]
                mempty
                []
                [holderKeyA]
    holdersOf v tokenA `requireCount` 3

-- | The chain's holder of the token with the given quantity at holder A.
holderWith :: View -> Integer -> IO TxIn
holderWith view q =
    case [ t
         | (t, o) <- Map.toList view
         , o ^. addrTxOutL == holderA
         , quantityOf tokenA o == q
         ] of
        [t] -> pure t
        ts -> fail ("setup: holder A has " <> show (length ts) <> " outputs of " <> show q)

-- * The daemon

config :: FilePath -> FilePath -> FilePath -> Bool -> DaemonConfig
config relay sock db request =
    DaemonConfig
        { dcRelaySocket = relay
        , dcListenSocket = sock
        , dcNetworkMagic = magic
        , dcByronEpochSlots = 42
        , dcReadyThresholdSlots = 60
        , dcSecurityParamK = 2160
        , dcDbPath = Just db
        , dcReconnectPolicy = defaultReconnectPolicy
        , dcProbeConfig = defaultProbeConfig
        , dcStaleAfterSeconds = 600
        , dcRebuildAssetIndex = request
        }
  where
    NetworkMagic magic = devnetMagic

{- | Run the daemon for the duration of the action, then stop it. The
previous run's socket file is removed first, so the wait observes this
run's bind.
-}
withDaemon :: String -> DaemonConfig -> IO a -> IO a
withDaemon run cfg action = labelled $ do
    removePathForcibly (dcListenSocket cfg)
    withAsync (runDaemon nullTracer cfg) $ \daemon -> do
        waitForFile (dcListenSocket cfg) 600
        requireRunning daemon "after binding its socket"
        r <- action
        requireRunning daemon "at the end of its run"
        pure r
  where
    labelled = handle $ \(e :: SomeException) ->
        throwIO (userError (run <> ": " <> displayException e))

-- * Answers

-- | The matches for every queried asset; any unavailability fails.
answers :: FilePath -> IO [[Match]]
answers sock = forM queriedAssets (fmap ansMatches . askAsset sock . assetBytes)

sameAnswers :: (String -> IO ()) -> String -> [[Match]] -> [[Match]] -> IO ()
sameAnswers report label expected actual =
    forM_ (zip3 queriedAssets expected actual) $ \(asset, e, a) ->
        when (e /= a) $
            report
                ( label
                    <> ", "
                    <> assetLabel asset
                    <> ": "
                    <> show a
                    <> " instead of "
                    <> show e
                )

{- | Poll the asset query until it answers a list. Before that, every
answer must be @asset_index_unavailable@ with reason @rebuilding@.
-}
awaitUpgrade :: FilePath -> Int -> Asset -> IO Answer
awaitUpgrade sock attempts asset = go attempts
  where
    go 0 = fail ("upgrade: " <> assetLabel asset <> " never answered a list")
    go n = do
        resp <- requestLine sock (uncurry assetLine (assetBytes asset))
        case successAnswer resp of
            Right answer -> pure answer
            Left _
                | unavailableReason resp == Just "rebuilding" ->
                    threadDelay 200_000 >> go (n - 1)
                | otherwise ->
                    fail ("upgrade: " <> assetLabel asset <> " answered " <> show resp)

unavailableReason :: ByteString -> Maybe Text
unavailableReason resp = case Aeson.decodeStrict' resp of
    Just (Aeson.Object o)
        | KM.lookup "error" o == Just "asset_index_unavailable"
        , Just (Aeson.String r) <- KM.lookup "reason" o ->
            Just r
    _ -> Nothing

-- | The daemon's @utxos_at@ answers for the two holder addresses.
holderUtxos :: FilePath -> IO [[(Text, ByteString)]]
holderUtxos sock = forM [holderA, holderB] (utxosAt sock . serialiseAddr)

-- * The store before the asset index

{- | Replace the closed store at the path with a directory holding only
the four column families that predate the asset index, with the raw
rows the daemon wrote into them.
-}
toPreChangeStore :: FilePath -> IO ()
toPreChangeStore db = do
    rows <-
        withDBCF db def (preChangeFamilies <> assetFamilies) $ \rdb ->
            forM (take (length preChangeFamilies) (columnFamilies rdb)) $ \cf ->
                withIterCF rdb cf $ \iter -> iterFirst iter >> collect iter
    let staged = db <> ".pre-change"
    withDBCF staged def{createIfMissing = True} preChangeFamilies $ \rdb ->
        forM_ (zip (columnFamilies rdb) rows) $ \(cf, kvs) ->
            forM_ kvs (uncurry (putCF rdb cf))
    removeDirectoryRecursive db
    renameDirectory staged db
  where
    collect iter = do
        valid <- iterValid iter
        if not valid
            then pure []
            else do
                e <- iterEntry iter
                iterNext iter
                maybe id (:) e <$> collect iter

preChangeFamilies, assetFamilies :: [(String, Config)]
preChangeFamilies =
    [ ("utxo-indexer.txin", def)
    , ("utxo-indexer.address", def)
    , ("utxo-indexer.observation", def)
    , ("utxo-indexer.rollback", def)
    ]
assetFamilies =
    [ ("utxo-indexer.asset", def)
    , ("utxo-indexer.meta", def)
    ]
