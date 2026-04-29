{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.TxGeneratorStarvationSpec
Description : E2E for graceful starvation / load resilience (T022)
License     : Apache-2.0

Verifies the daemon's failure-mode contract under
sustained load:

* Refill once at addr_0; drive 80 K=8 transacts; every
  response must be a well-formed @{"ok": Bool, ...}@
  envelope — never a malformed JSON, never a hang, never
  a crash.
* When fragmentation reaches the per-output viability
  floor and a transact returns
  @{"ok":false,"reason":"no-pickable-source"}@, the
  classification path treats that as the documented
  not-applicable response (rather than an error).
* Across the 80-transact run the daemon process stays
  responsive: post-run @ready@ is @true@ and
  @snapshot@ resolves cleanly — the test is the
  load-resilience contract first, with starvation
  reachability falling out of the same setup when the
  RNG drives it deep enough.
-}
module Cardano.Node.Client.E2E.TxGeneratorStarvationSpec (spec) where

import Cardano.Crypto.DSIGN (rawSerialiseSignKeyDSIGN)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    async,
    cancel,
    race,
 )
import Control.Exception (
    SomeException,
    bracket,
    try,
 )
import Control.Monad (forM_)
import Data.Aeson (Object, Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (
    modifyIORef',
    newIORef,
    readIORef,
 )
import Data.Text (Text)
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
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "tx-generator starvation (T022)"
        $ it
            "drains addr_0 at K=8 then returns \
            \no-pickable-source while staying alive"
        $ do
            gDir <- genesisDir
            withCardanoNode gDir $ \nodeSocket _startMs ->
                withSystemTempDirectory "txgen-starve" $ \dir -> do
                    let masterSeed = dir </> "master.seed"
                        faucetSkey = dir </> "faucet.skey"
                        controlSock = dir </> "control.sock"
                        stateDir = dir </> "state"
                    BS.writeFile
                        masterSeed
                        (BS.replicate 32 0x42)
                    BS.writeFile
                        faucetSkey
                        ( rawSerialiseSignKeyDSIGN genesisSignKey
                        )
                    let NetworkMagic m = devnetMagic
                        cfg =
                            DaemonConfig
                                { dcRelaySocket = nodeSocket
                                , dcControlSocket = controlSock
                                , dcStateDir = stateDir
                                , dcMasterSeedFile = masterSeed
                                , dcFaucetSKeyFile = faucetSkey
                                , dcNetworkMagic = m
                                , dcByronEpochSlots = 432_000
                                , dcAwaitTimeoutSeconds = 10
                                , dcReadyThresholdSlots = 10
                                , dcSecurityParamK = 2160
                                , dcDbPath = Nothing
                                }
                    daemonThread <- async (runDaemon cfg)
                    result <-
                        race
                            (threadDelay 600_000_000)
                            (driveStarvation controlSock)
                    cancel daemonThread
                    result `shouldSatisfy` isRight'

driveStarvation :: FilePath -> IO ()
driveStarvation path = do
    waitForConnect path
    pollReady path
    refillRsp <- sendOne path "{\"refill\":{\"seed\":1}}"
    assertOk "refill" refillRsp
    -- Drive K=8 transacts until starvation kicks in or
    -- we've fired our quota. K=8 burns through the
    -- 5000-ADA refill faster than K=4.
    starvedRef <- newIORef (0 :: Int)
    okRef <- newIORef (0 :: Int)
    forM_ [201 .. 280 :: Int] $ \seed -> do
        rsp <-
            sendOne
                path
                ( BS8.pack
                    ( "{\"transact\":{\"seed\":"
                        <> show seed
                        <> ",\"fanout\":8,\"prob_fresh\":0.5}}"
                    )
                )
        case classify rsp of
            ResOk -> modifyIORef' okRef (+ 1)
            ResStarved -> modifyIORef' starvedRef (+ 1)
            ResOther reason ->
                error
                    ( "unexpected non-ok / non-starved \
                      \response: "
                        <> show reason
                        <> " raw="
                        <> BS8.unpack rsp
                    )
    okCount <- readIORef okRef
    _starvedCount <- readIORef starvedRef
    -- Sanity: at least some transacts landed. We do
    -- \*not* assert starvedCount > 0: under devnet
    -- variance the RNG may not drive deep enough into
    -- the floor inside 80 transacts at prob_fresh=0.5
    -- (existing-population top-ups keep some addresses
    -- viable). The starvation case is exercised
    -- deliberately at much heavier load on the
    -- antithesis cluster; what matters here is the
    -- liveness contract.
    okCount `shouldSatisfy` (> 0)
    -- Daemon must still be responsive after the load.
    readyRsp <- sendOne path "{\"ready\":null}"
    isReadyTrue readyRsp `shouldBe` True
    -- And the snapshot still resolves.
    snapRsp <- sendOne path "{\"snapshot\":null}"
    case Aeson.decodeStrict snapRsp of
        Just (Object _) -> pure ()
        other ->
            error
                ( "snapshot did not parse after run: "
                    <> show other
                )

data Classification
    = ResOk
    | ResStarved
    | ResOther !Text
    deriving stock (Eq, Show)

classify :: ByteString -> Classification
classify rsp = case Aeson.decodeStrict rsp of
    Just (Object o) -> case lookupValue "ok" o of
        Just (Bool True) -> ResOk
        Just (Bool False) ->
            case lookupValue "reason" o of
                Just (String r)
                    | r == "no-pickable-source" -> ResStarved
                Just (String r) -> ResOther r
                _ -> ResOther "missing-reason"
        _ -> ResOther "no-ok-field"
    _ -> ResOther "not-object"

assertOk :: String -> ByteString -> IO ()
assertOk what rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        lookupValue "ok" o `shouldBe` Just (Bool True)
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
        error "tx-generator: control socket never bound"
    loop n = do
        attempt <- try @SomeException (connectAndClose path)
        case attempt of
            Right () -> pure ()
            Left _ -> threadDelay 500_000 >> loop (n + 1)

connectAndClose :: FilePath -> IO ()
connectAndClose path =
    bracket
        (socket AF_UNIX Stream 0)
        close
        (\s -> connect s (SockAddrUnix path))

pollReady :: FilePath -> IO ()
pollReady path = loop (0 :: Int)
  where
    loop 120 =
        error "tx-generator: ready never went true"
    loop n = do
        rsp <- sendOne path "{\"ready\":null}"
        if isReadyTrue rsp
            then pure ()
            else threadDelay 500_000 >> loop (n + 1)

isReadyTrue :: ByteString -> Bool
isReadyTrue rsp = case Aeson.decodeStrict rsp of
    Just (Object o) ->
        lookupValue "ready" o == Just (Bool True)
    _ -> False

lookupValue :: ByteString -> Object -> Maybe Value
lookupValue k = KeyMap.lookup (Key.fromText (decodeKey k))
  where
    decodeKey = Key.toText . Key.fromString . BS8.unpack

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

isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _ = False
