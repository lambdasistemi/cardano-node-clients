{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.AssetDisclosureSpec
Description : The asset answer's freshness against a devnet node
License     : Apache-2.0

Boots a real @cardano-node@ devnet, runs the @utxo-indexer@ daemon
against it with a RocksDB store, and reads the disclosure of its
@utxos_with_asset@ answer:

* while the daemon follows the node, the answer settles at @synced@
  with no limit, stating the devnet's magic (read from the harness
  that configured the node) and the daemon's origin, all-address
  coverage;
* with the node stopped, the same daemon answers from the store it
  already holds — a success answer with a point — whose freshness is
  @disconnected@ and whose limits name it.

The node is stopped by the harness's restart, which terminates the
node process before starting a new one; the answers are read while it
is down.
-}
module Cardano.Node.Client.E2E.AssetDisclosureSpec (spec) where

import Cardano.Node.Client.E2E.Devnet (withRestartableCardanoNode)
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    assetLine,
    decoded,
    objectWithKeys,
    requestLine,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, poll, withAsync)
import Control.Exception (IOException, try)
import Control.Tracer (nullTracer)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (doesPathExist)
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
spec =
    describe "utxo-indexer socket: asset answer freshness on a devnet (E2E)" $
        it
            "answers synced with no limit while following, and disconnected from its store once the node stops"
            runDisclosureE2E

runDisclosureE2E :: IO ()
runDisclosureE2E = do
    gDir <- genesisDir
    withRestartableCardanoNode gDir $ \nodeSock _ restart ->
        withSystemTempDirectory "asset-disclosure-e2e" $ \tmp -> do
            let daemonSock = tmp </> "indexer.sock"
                NetworkMagic magic = devnetMagic
                cfg =
                    DaemonConfig
                        { dcRelaySocket = nodeSock
                        , dcListenSocket = daemonSock
                        , dcNetworkMagic = magic
                        , dcByronEpochSlots = 42
                        , dcReadyThresholdSlots = 60
                        , dcSecurityParamK = 2160
                        , dcDbPath = Just (tmp </> "db")
                        , dcReconnectPolicy = defaultReconnectPolicy
                        , dcProbeConfig = defaultProbeConfig
                        , dcStaleAfterSeconds = 600
                        }
            withAsync (runDaemon nullTracer cfg) $ \daemon -> do
                waitForFile daemonSock 600
                requireRunning daemon "after binding its socket"

                followed <- askUntil daemonSock 1_200 "synced"
                KM.lookup "limits" followed `shouldBe` Just (Aeson.toJSON ([] :: [Text]))
                KM.lookup "network" followed
                    `shouldBe` Just (Aeson.object ["magic" .= (magic :: Word32)])
                KM.lookup "coverage" followed
                    `shouldBe` Just
                        ( Aeson.object
                            ["start" .= ("origin" :: Text), "addresses" .= ("all" :: Text)]
                        )
                let followedSlot = pointSlot followed
                behindOf followed
                    `shouldBe` fmap
                        (\tip -> if tip > followedSlot then tip - followedSlot else 0)
                        (tipOf followed)

                withAsync restart $ \_ -> do
                    stopped <- askUntil daemonSock 600 "disconnected"
                    KM.lookup "limits" stopped
                        `shouldBe` Just (Aeson.toJSON ["disconnected" :: Text])
                    pointSlot stopped `shouldSatisfy` (>= followedSlot)
                    requireRunning daemon "while the node is stopped"

-- * Asking the daemon

{- | Ask for an asset nobody holds until the answer's freshness has the
given status, polling every 100 ms up to the given number of times.
Only a success answer carrying all six members can match; anything
else is asked again, and the last raw answer is reported on timeout.
-}
askUntil :: FilePath -> Int -> Text -> IO (KM.KeyMap Aeson.Value)
askUntil sock tries wanted = go tries Nothing
  where
    go n lastSeen
        | n <= 0 =
            fail
                ( "freshness never reached "
                    <> show wanted
                    <> "; last answer "
                    <> show lastSeen
                )
        | otherwise = do
            asked <- try (requestLine sock (assetLine (BS.replicate 28 0x11) "tok"))
            case asked :: Either IOException ByteString of
                Left e -> threadDelay 100_000 >> go (n - 1) (Just (show e))
                Right resp -> case objectWithKeys answerKeys =<< decoded resp of
                    Right answer
                        | statusOf answer == Just wanted -> pure answer
                    _ -> threadDelay 100_000 >> go (n - 1) (Just (show resp))

answerKeys :: [Text]
answerKeys = ["coverage", "freshness", "limits", "network", "point", "utxos"]

freshnessMember :: Aeson.Key -> KM.KeyMap Aeson.Value -> Maybe Aeson.Value
freshnessMember k answer = case KM.lookup "freshness" answer of
    Just (Aeson.Object f) -> KM.lookup k f
    _ -> Nothing

statusOf :: KM.KeyMap Aeson.Value -> Maybe Text
statusOf answer = case freshnessMember "status" answer of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

tipOf :: KM.KeyMap Aeson.Value -> Maybe Word64
tipOf answer = freshnessMember "tipSlot" answer >>= word

behindOf :: KM.KeyMap Aeson.Value -> Maybe Word64
behindOf answer = freshnessMember "slotsBehind" answer >>= word

pointSlot :: KM.KeyMap Aeson.Value -> Word64
pointSlot answer = case KM.lookup "point" answer of
    Just (Aeson.Object p) | Just s <- KM.lookup "slot" p >>= word -> s
    other -> error ("point: " <> show other)

word :: Aeson.Value -> Maybe Word64
word v = case Aeson.fromJSON v of
    Aeson.Success w -> Just w
    Aeson.Error _ -> Nothing

-- * Liveness

requireRunning :: Async () -> String -> IO ()
requireRunning thread ctx =
    poll thread >>= \case
        Just (Left e) ->
            expectationFailure ("daemon died " <> ctx <> ": " <> show e)
        Just (Right ()) ->
            expectationFailure ("daemon exited " <> ctx)
        Nothing -> pure ()

waitForFile :: FilePath -> Int -> IO ()
waitForFile path tries = do
    present <- doesPathExist path
    if present
        then pure ()
        else
            if tries <= 0
                then expectationFailure ("never appeared: " <> path)
                else threadDelay 100_000 >> waitForFile path (tries - 1)
