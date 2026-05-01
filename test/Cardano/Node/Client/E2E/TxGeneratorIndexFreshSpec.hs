{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorIndexFreshSpec
Description : E2E for the post-reconnect indexer-fresh gate (issue #109)
License     : Apache-2.0

After PR #105 the tx-generator's N2C bearer is supervised
via 'runReconnectLoop'. The supervisor flips upstream
status to 'UpstreamConnected' as soon as the new bearer
is established and the LSQ probe answers — before the
embedded chain-sync follower has caught the indexer's
UTxO view back up to the new tip. During that window the
indexer's local UTxO view is stale.

Without the gate added by issue #109, a refill ticked into
that window queries faucet UTxOs, sees rows the
post-reconnect chain has already spent, builds a refill tx
against them, and gets a 'ConwayMempoolFailure
\"All inputs are spent\"' rejection. Antithesis on commit
@329a599@ recorded 111 such failures across 95 forks
tripping the @tx_generator_refill_submit_rejected@
Always-assertion.

This spec drives a real relay restart via
'withRestartableCardanoNode' and pounds refill+transact
in a tight loop across the post-reconnect settle window.
The contract:

* the daemon's 'Async' never exits,
* eventually a refill succeeds again (chain-sync resumes
  past the reconnect anchor and the freshness gate
  releases),
* no refill response in the entire post-restart window
  ever carries a @submit-rejected@ reason whose text
  matches @\"All inputs are spent\"@ — that exact reason
  is the regression we are preventing.

Acceptance covers User Story 1 (refill arm) and User Story
2 (transact arm) of the spec at
@specs\/037-tx-gen-indexer-fresh\/spec.md@.
-}
module Cardano.Node.Client.E2E.TxGeneratorIndexFreshSpec (spec) where

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Node.Client.E2E.Devnet (
    withRestartableCardanoNode,
 )
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    Async,
    async,
    cancel,
    poll,
    race,
 )
import Control.Exception (
    SomeException,
    bracket,
    try,
 )
import Control.Monad (replicateM)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (find)
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    SocketType (Stream),
    close,
    connect,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import Ouroboros.Network.Magic (NetworkMagic (..))
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
    describe "tx-generator indexer-fresh gate (issue #109)"
        $ it
            "no refill ever reports \"All inputs are spent\" \
            \across a relay restart, and refills resume \
            \after the freshness gate releases"
        $ do
            gDir <- genesisDir
            withRestartableCardanoNode gDir $
                \nodeSock _startMs restart ->
                    withSystemTempDirectory "txgen-indexfresh" $
                        \dir -> do
                            let masterSeed = dir </> "master.seed"
                                faucetSkey = dir </> "faucet.skey"
                                stateDir = dir </> "state"
                                ctlSock = dir </> "control.sock"
                            BS.writeFile
                                masterSeed
                                (BS.replicate 32 0x37)
                            BS.writeFile
                                faucetSkey
                                ( rawSerialiseSignKeyDSIGN
                                    genesisSignKey
                                )
                            let cfg =
                                    mkCfg
                                        nodeSock
                                        ctlSock
                                        stateDir
                                        masterSeed
                                        faucetSkey
                            runScenario cfg ctlSock restart

runScenario ::
    DaemonConfig ->
    FilePath ->
    IO () ->
    IO ()
runScenario cfg ctl restart = do
    daemonT <- async (runDaemon cfg)
    result <-
        race
            (threadDelay 600_000_000)
            (driveScenario ctl restart daemonT)
    cancel daemonT
    case result of
        Right () -> pure ()
        Left _ ->
            expectationFailure "scenario timed out (10 min)"

driveScenario ::
    FilePath ->
    IO () ->
    Async () ->
    IO ()
driveScenario sockPath restart daemonT = do
    waitForConnect sockPath
    requireRunning daemonT "after listen-socket bind"
    pollReady sockPath
    -- Sanity: a refill before the restart succeeds
    -- (steady state baseline). If this fails the test is
    -- not measuring what we think it is.
    baseline <- sendOne sockPath "{\"refill\":{\"seed\":1}}"
    assertOk "baseline refill" baseline

    -- Drive the relay restart. 'restart' blocks until the
    -- new relay's LSQ answers; the supervisor then has to
    -- detect the disconnect on its side, reconnect, and
    -- re-prime chain-sync. The window between the
    -- supervisor's setUpstreamStatus UpstreamConnected
    -- and the first applied 'rollForward' is the
    -- freshness window the gate exists to handle.
    restart

    -- Pound refill in a tight loop for several seconds,
    -- capturing every response. Counter-evidence (the
    -- regression we are guarding against) is any refill
    -- whose reason text matches "All inputs are spent" —
    -- the exact ConwayMempoolFailure that tripped
    -- tx_generator_refill_submit_rejected on Antithesis
    -- @329a599@.
    responses <-
        replicateM 60 $ do
            r <- sendOne sockPath "{\"refill\":{\"seed\":2}}"
            requireRunning
                daemonT
                "during post-restart refill loop"
            threadDelay 200_000
            pure r

    -- (a) at least one refill must eventually succeed
    --     post-restart; that proves the freshness gate
    --     released and the daemon resumed normal duty.
    let oks = filter isOk responses
    null oks
        `shouldBe` False

    -- (b) no refill in the window may report
    --     "All inputs are spent". This is the regression
    --     check.
    let badReasons =
            [ reason
            | r <- responses
            , Just reason <- [extractFailReason r]
            , "All inputs are spent" `T.isInfixOf` reason
            ]
    badReasons `shouldSatisfy` null

    -- (c) similarly poke the transact arm a few times to
    --     confirm it is also gated. We just assert the
    --     daemon stays alive and never crashes; a per-
    --     reason assertion for transact is captured in the
    --     same regression check at the daemon level (see
    --     comment on 'doTransact' in
    --     Cardano.Node.Client.TxGenerator.Daemon).
    transactRsps <-
        replicateM 10 $ do
            r <-
                sendOne
                    sockPath
                    "{\"transact\":{\"seed\":3,\"fanout\":2,\
                    \\"prob_fresh\":0.5}}"
            requireRunning
                daemonT
                "during post-restart transact loop"
            threadDelay 200_000
            pure r
    let crashlike =
            find
                (\r -> not (isOk r) && isNothing (extractFailReason r))
                transactRsps
    crashlike
        `shouldSatisfy` ( \case
                            Nothing -> True
                            Just bad ->
                                error
                                    ( "transact: malformed response: "
                                        <> BS8.unpack bad
                                    )
                        )

mkCfg ::
    FilePath ->
    FilePath ->
    FilePath ->
    FilePath ->
    FilePath ->
    DaemonConfig
mkCfg nodeSocket controlSock stateDir masterSeed faucetSkey =
    let NetworkMagic m = devnetMagic
     in DaemonConfig
            { dcRelaySocket = nodeSocket
            , dcControlSocket = controlSock
            , dcStateDir = stateDir
            , dcMasterSeedFile = masterSeed
            , dcFaucetSKeyFile = faucetSkey
            , dcNetworkMagic = m
            , dcByronEpochSlots = 432_000
            , dcAwaitTimeoutSeconds = 30
            , dcReadyThresholdSlots = 10
            , dcSecurityParamK = 2160
            , dcDbPath = Nothing
            , dcReconnectPolicy = defaultReconnectPolicy
            , dcProbeConfig = defaultProbeConfig
            }

requireRunning :: Async () -> String -> IO ()
requireRunning thread ctx =
    poll thread >>= \case
        Just (Left e) ->
            expectationFailure $
                "daemon crashed " <> ctx <> ": " <> show e
        Just (Right ()) ->
            expectationFailure $
                "daemon exited cleanly " <> ctx
        Nothing -> pure ()

isOk :: ByteString -> Bool
isOk rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        KM.lookup "ok" o == Just (Bool True)
    _ -> False

extractFailReason :: ByteString -> Maybe T.Text
extractFailReason rsp = case Aeson.decodeStrict rsp of
    Just (Object o) -> case KM.lookup "reason" o of
        Just (String t) -> Just t
        _ -> Nothing
    _ -> Nothing

assertOk :: String -> ByteString -> IO ()
assertOk what rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        KM.lookup "ok" o `shouldBe` Just (Bool True)
    other ->
        error
            ( what
                <> ": not a JSON object: "
                <> show other
                <> " raw="
                <> BS8.unpack rsp
            )

waitForConnect :: FilePath -> IO ()
waitForConnect path = loop (0 :: Int)
  where
    loop 120 =
        error
            ( "tx-generator: control socket "
                <> path
                <> " never bound within 60s"
            )
    loop n = do
        attempt <-
            try @SomeException (connectAndClose path)
        case attempt of
            Right () -> pure ()
            Left _ ->
                threadDelay 500_000 >> loop (n + 1)

connectAndClose :: FilePath -> IO ()
connectAndClose path =
    bracket
        (socket AF_UNIX Stream 0)
        close
        (\s -> connect s (SockAddrUnix path))

pollReady :: FilePath -> IO ()
pollReady path = loop (0 :: Int)
  where
    loop 240 =
        error
            "tx-generator: ready never went true within 120s"
    loop n = do
        rsp <- sendOne path "{\"ready\":null}"
        if isReadyTrue rsp
            then pure ()
            else threadDelay 500_000 >> loop (n + 1)

isReadyTrue :: ByteString -> Bool
isReadyTrue rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        KM.lookup "ready" o == Just (Bool True)
    _ -> False

sendOne :: FilePath -> ByteString -> IO ByteString
sendOne path req =
    bracket
        (socket AF_UNIX Stream 0)
        close
        ( \s -> do
            connect s (SockAddrUnix path)
            Net.sendAll s (req <> "\n")
            recvAll s BS.empty
        )
  where
    recvAll s acc = do
        chunk <- Net.recv s 4096
        if BS.null chunk
            then pure acc
            else recvAll s (acc <> chunk)
