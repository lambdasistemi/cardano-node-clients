{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.DaemonDisclosureSpec
Description : The daemon discloses its own follower configuration
License     : Apache-2.0

The coverage an asset answer states is the coverage its store
recorded when it was created, the network magic is the one the
follower connects with, and the stale bound comes from
@--stale-after-seconds@.

* 'parseDaemonArgs' reads @--stale-after-seconds@ (default 600, a
  positive whole number, anything else refused naming the flag) and
  keeps every other flag as it was.
* @ over a store it created, with no node behind its relay
  socket, records the coverage of its own configuration in the store,
  answers with its configured magic and that recorded coverage, and a
  freshness that turns stale once the configured bound has passed
  without progress.
* @ over a store created before coverage was recorded
  answers with an unknown coverage and the @ limit,
  and writes no record into it.
-}
module Cardano.Node.Client.UTxOIndexer.DaemonDisclosureSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash (UnsafeHash))
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Credential (
    Credential (KeyHashObj),
    StakeReference (StakeRefNull),
 )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy (..),
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.UTxOIndexer.Columns (Cols (..))
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    parseDaemonArgs,
    runDaemon,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    BuildCoverage (..),
    IndexerHandle (..),
    InterestSet (..),
    UtxoOp (..),
    decodeBuildCoverage,
    withRocksDBIndexer,
    withRocksDBIndexerRunner,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    assetLine,
    decoded,
    objectWithKeys,
    requestLine,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (fromLeft, isLeft, isRight)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Word (Word32, Word64, Word8)
import Database.KV.Transaction (RunTransaction (..), query)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "utxo-indexer daemon: disclosure from its own configuration" $ do
    describe "parseDaemonArgs" $ do
        it "defaults the stale bound to 600 seconds" $
            (dcStaleAfterSeconds <$> parsed required) `shouldBeRight` 600

        it "sets the stale bound from --stale-after-seconds" $
            forM_ [1, 7, 600, 86_400, maxBound :: Word64] $ \n ->
                ( dcStaleAfterSeconds
                    <$> parsed (required <> ["--stale-after-seconds", show n])
                )
                    `shouldBeRight` n

        it "refuses a stale bound that is not a positive whole number, naming the flag" $ do
            -- the flag itself is taken: each refusal below is about its value
            parseDaemonArgs (required <> ["--stale-after-seconds", "5"])
                `shouldSatisfy` isRight
            forM_ ["abc", "1.5", "-3", "0", "", "6e2", "18446744073709551616"] $ \v -> do
                let r = parseDaemonArgs (required <> ["--stale-after-seconds", v])
                r `shouldSatisfy` isLeft
                fromLeft "" r
                    `shouldSatisfy` ("--stale-after-seconds" `isInfixOf`)

        it "keeps every required flag and the other defaults as they were" $ do
            cfg <- either (fail . ("parse: " <>)) pure (parseDaemonArgs required)
            dcRelaySocket cfg `shouldBe` "/run/node.sock"
            dcListenSocket cfg `shouldBe` "/run/indexer.sock"
            dcNetworkMagic cfg `shouldBe` 1_097_911_063
            dcByronEpochSlots cfg `shouldBe` 21_600
            dcReadyThresholdSlots cfg `shouldBe` 60
            dcSecurityParamK cfg `shouldBe` 2_160
            dcDbPath cfg `shouldBe` Nothing
            dcReconnectPolicy cfg `shouldBe` defaultReconnectPolicy
            dcProbeConfig cfg `shouldBe` defaultProbeConfig

        it "reads every optional flag as before" $ do
            cfg <-
                either (fail . ("parse: " <>)) pure $
                    parseDaemonArgs $
                        required
                            <> [ "--ready-threshold-slots"
                               , "9"
                               , "--security-param-k"
                               , "11"
                               , "--db-path"
                               , "/var/db"
                               , "--reconnect-initial-ms"
                               , "13"
                               , "--reconnect-max-ms"
                               , "17"
                               , "--reconnect-reset-threshold-ms"
                               , "19"
                               , "--node-ready-timeout-ms"
                               , "23"
                               ]
            dcReadyThresholdSlots cfg `shouldBe` 9
            dcSecurityParamK cfg `shouldBe` 11
            dcDbPath cfg `shouldBe` Just "/var/db"
            dcReconnectPolicy cfg `shouldBe` ReconnectPolicy 13 17 19
            show (dcProbeConfig cfg) `shouldSatisfy` ("Just 23" `isInfixOf`)

        it "refuses a missing required flag, naming it" $
            forM_ ["--relay-socket", "--listen", "--network-magic", "--byron-epoch-slots"] $ \flag -> do
                let r = parseDaemonArgs (withoutFlag flag required)
                fromLeft "" r `shouldSatisfy` (flag `isInfixOf`)

        it "refuses an argument no flag takes" $
            parseDaemonArgs (required <> ["--frobnicate", "1"]) `shouldSatisfy` isLeft

    describe "runDaemon" $ do
        it "states its magic and the coverage it recorded in the store it created" $
            answering OwnStore 3_141_592 600 $ \sock -> do
                answer <- askHeld sock
                KM.lookup "network" answer
                    `shouldBe` Just (Aeson.object ["magic" .= (3_141_592 :: Word32)])
                KM.lookup "coverage" answer
                    `shouldBe` Just
                        ( Aeson.object
                            [ "start" .= ("origin" :: Text)
                            , "addresses" .= ("all" :: Text)
                            ]
                        )

        it "records the coverage of its own configuration in a store it creates" $ do
            (_, record) <- withDaemonOver OwnStore 42 600 $ \_ -> pure ()
            (decodeBuildCoverage =<< record)
                `shouldBe` Just (BuildCoverage Nothing IndexAll)

        it "states unknown coverage over a store created before coverage was recorded" $
            answering LegacyStore 42 600 $ \sock -> do
                answer <- askHeld sock
                KM.lookup "coverage" answer
                    `shouldBe` Just
                        ( Aeson.object
                            [ "start" .= ("unknown" :: Text)
                            , "addresses" .= ("unknown" :: Text)
                            ]
                        )
                KM.lookup "limits" answer
                    `shouldBe` Just (Aeson.toJSON ["coverage_unknown", "catching_up" :: Text])

        it "writes no record into a store created before coverage was recorded" $
            withDaemonOver LegacyStore 42 600 (\_ -> pure ())
                >>= (`shouldBe` Nothing) . snd

        it "is catching_up, not stale, with no node behind it inside the default bound" $
            answering OwnStore 42 600 $ \sock -> do
                answer <- askHeld sock
                freshnessStatus answer `shouldBe` Just "catching_up"
                KM.lookup "limits" answer
                    `shouldBe` Just (Aeson.toJSON ["catching_up" :: Text])

        it "turns stale once the configured bound passes without progress" $
            answering OwnStore 42 1 $ \sock -> do
                answer <- untilSecondsSince sock 2
                freshnessStatus answer `shouldBe` Just "stale"
                KM.lookup "limits" answer
                    `shouldBe` Just (Aeson.toJSON ["stale" :: Text])
  where
    parsed = parseDaemonArgs
    answering store magic bound act = fst <$> withDaemonOver store magic bound act

shouldBeRight :: (Show a, Eq a) => Either String a -> a -> IO ()
shouldBeRight r expected = case r of
    Right a -> a `shouldBe` expected
    Left why -> expectationFailure ("refused: " <> why)

required :: [String]
required =
    [ "--relay-socket"
    , "/run/node.sock"
    , "--listen"
    , "/run/indexer.sock"
    , "--network-magic"
    , "1097911063"
    , "--byron-epoch-slots"
    , "21600"
    ]

withoutFlag :: String -> [String] -> [String]
withoutFlag flag = go
  where
    go (k : _ : rest) | k == flag = rest
    go (x : rest) = x : go rest
    go [] = []

-- * The daemon over a store, with no node

-- | How the store the daemon serves came to hold its blocks.
data Store
    = -- | The daemon created it; the blocks were applied afterwards.
      OwnStore
    | -- | Created and filled before coverage was recorded.
      LegacyStore

{- | Run the daemon with the given magic and stale bound and a relay
socket nothing listens on, over a store holding one block; the action
gets the daemon's socket. Returns the action's result and the store's
build-coverage record as it stands once the daemon has stopped.
-}
withDaemonOver :: Store -> Word32 -> Word64 -> (FilePath -> IO a) -> IO (a, Maybe ByteString)
withDaemonOver store magic bound action =
    withSystemTempDirectory "daemon-disclosure" $ \tmp -> do
        let db = tmp </> "db"
            sock = tmp </> "indexer.sock"
            cfg =
                DaemonConfig
                    { dcRelaySocket = tmp </> "no-node.sock"
                    , dcListenSocket = sock
                    , dcNetworkMagic = magic
                    , dcByronEpochSlots = 21_600
                    , dcReadyThresholdSlots = 60
                    , dcSecurityParamK = 2_160
                    , dcDbPath = Just db
                    , dcReconnectPolicy = defaultReconnectPolicy
                    , dcProbeConfig = defaultProbeConfig
                    , dcStaleAfterSeconds = bound
                    , dcRebuildAssetIndex = False
                    }
            serving :: IO b -> IO b
            serving act =
                withAsync (runDaemon nullTracer cfg) $ \_ -> do
                    waitAnswering sock 200
                    act
        case store of
            OwnStore -> serving (pure ())
            LegacyStore -> pure ()
        withRocksDBIndexer db seedStore
        r <- serving (action sock)
        (,) r <$> storedRecord db

-- | The build-coverage record of a closed store, as stored.
storedRecord :: FilePath -> IO (Maybe ByteString)
storedRecord db =
    withRocksDBIndexerRunner db $ \_ runner ->
        runTransaction runner (query MetaCol "build-coverage")

{- | Wait until the daemon answers on its socket: the socket file
appears at bind, before the server listens.
-}
waitAnswering :: FilePath -> Int -> IO ()
waitAnswering path tries = do
    answered <- try (requestLine path "not json")
    case answered :: Either IOException ByteString of
        Right _ -> pure ()
        Left e
            | tries <= 0 -> expectationFailure ("never answered: " <> show e)
            | otherwise -> threadDelay 50_000 >> waitAnswering path (tries - 1)

askHeld :: FilePath -> IO (KM.KeyMap Aeson.Value)
askHeld sock = do
    resp <- requestLine sock (assetLine assetPolicy "tok")
    either (\why -> fail (why <> "; answer was " <> show resp)) pure $
        objectWithKeys
            ["coverage", "freshness", "limits", "network", "point", "utxos"]
            =<< decoded resp

freshnessMember :: Aeson.Key -> KM.KeyMap Aeson.Value -> Maybe Aeson.Value
freshnessMember k answer = case KM.lookup "freshness" answer of
    Just (Aeson.Object f) -> KM.lookup k f
    _ -> Nothing

freshnessStatus :: KM.KeyMap Aeson.Value -> Maybe Aeson.Value
freshnessStatus = freshnessMember "status"

-- | Ask until the answer reports at least @n@ seconds since progress.
untilSecondsSince :: FilePath -> Word64 -> IO (KM.KeyMap Aeson.Value)
untilSecondsSince sock n = go (100 :: Int)
  where
    go tries = do
        answer <- askHeld sock
        case freshnessMember "secondsSinceProgress" answer of
            Just v
                | Aeson.Success w <- Aeson.fromJSON @Word64 v, w >= n -> pure answer
            other
                | tries <= 0 ->
                    fail ("secondsSinceProgress stayed " <> show other)
                | otherwise -> threadDelay 100_000 >> go (tries - 1)

-- * Store fixture

assetPolicy :: ByteString
assetPolicy = BS.replicate 28 0x11

seedStore :: IndexerHandle -> IO ()
seedStore h =
    applyAtSlot
        h
        (SlotNo 5)
        (BlockHash (BS.replicate 32 5))
        [ UtxoCreate
            (TxIn (BS.replicate 32 0x5A) 0)
            (Address (serialiseAddr (addressOf 0xA1)))
            (TxOut (serialize' (Ledger.eraProtVerLow @ConwayEra) out))
        ]
  where
    out =
        mkBasicTxOut @ConwayEra
            (addressOf 0xA1)
            ( Mary.valueFromList
                (Coin 2_000_000)
                [
                    ( Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort assetPolicy)))
                    , Mary.AssetName "tok"
                    , 3
                    )
                ]
            )

addressOf :: Word8 -> Addr
addressOf b =
    Addr
        Testnet
        (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 b)))))
        StakeRefNull
