{- |
Module      : Cardano.Node.Client.N2C.LocalStateQuerySpec
Description : LocalStateQuery liveness regression tests
License     : Apache-2.0

Node-free tests for LocalStateQuery client liveness when a server accepts a
query but never sends its result.
-}
module Cardano.Node.Client.N2C.LocalStateQuerySpec (spec) where

import Cardano.Node.Client.N2C.Connection (newLSQChannelWithTimeout)
import Cardano.Node.Client.N2C.LocalStateQuery (
    mkLocalStateQueryClient,
    monitorLocalStateQueryConnection,
    queryAcquiredLSQ,
    queryLSQ,
    withAcquiredLSQ,
 )
import Cardano.Node.Client.N2C.Types (
    ConnectionLost (..),
    LSQChannel (..),
    LocalStateQueryTimeout (..),
 )
import Control.Concurrent (myThreadId, threadDelay)
import Control.Concurrent.Async (Async, waitCatch, withAsync)
import Control.Concurrent.STM (
    TMVar,
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTVarIO,
    retry,
    takeTMVar,
 )
import Control.Exception (
    Exception,
    SomeException,
    displayException,
    finally,
    fromException,
    throwIO,
 )
import Control.Monad (void)
import Network.TypedProtocol.Stateful.Proofs qualified as Stateful
import Ouroboros.Consensus.Ledger.Query (Query (GetChainPoint))
import Ouroboros.Network.Protocol.LocalStateQuery.Client qualified as Client
import Ouroboros.Network.Protocol.LocalStateQuery.Server (
    LocalStateQueryServer (..),
    ServerStAcquired (..),
    ServerStAcquiring (..),
    ServerStIdle (..),
    localStateQueryServerPeer,
 )
import Ouroboros.Network.Protocol.LocalStateQuery.Type (State (StateIdle))
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec :: Spec
spec = describe "Cardano.Node.Client.N2C.LocalStateQuery" $ do
    it "bounds a stalled acquired query" $ do
        result <- timeout 2_000_000 stalledQueryScenario
        result `shouldBe` Just ()
    it
        "wakes a pending query when its connection terminates"
        terminatingConnectionScenario

stalledQueryScenario :: IO ()
stalledQueryScenario = do
    ch <- newLSQChannelWithTimeout 2 responseTimeout
    monitorThread <- newEmptyTMVarIO
    actionThread <- newEmptyTMVarIO
    connectionStarted <- newEmptyTMVarIO
    connectionStopped <- newEmptyTMVarIO
    queryAccepted <- newEmptyTMVarIO
    let connection = do
            caller <- myThreadId
            atomically $ putTMVar monitorThread caller
            monitorLocalStateQueryConnection ch $
                ( do
                    running <- myThreadId
                    atomically $ putTMVar actionThread running
                    atomically (putTMVar connectionStarted ())
                    >> void
                        ( Stateful.connect
                            StateIdle
                            ( Client.localStateQueryClientPeer $
                                mkLocalStateQueryClient ch
                            )
                            ( localStateQueryServerPeer $
                                stalledServer queryAccepted
                            )
                        )
                )
                    `finally` atomically (putTMVar connectionStopped ())
    withAsync connection $ \connectionThread -> do
        atomically $ void $ takeTMVar connectionStarted
        expectedThread <- atomically $ takeTMVar monitorThread
        actualThread <- atomically $ takeTMVar actionThread
        actualThread `shouldBe` expectedThread
        withAsync
            ( withAcquiredLSQ ch $ \acquired ->
                queryAcquiredLSQ acquired GetChainPoint
            )
            $ \queryThread -> do
                accepted <-
                    timeout 500_000 $
                        atomically $
                            takeTMVar queryAccepted
                accepted `shouldBe` Just ()
                threadDelay 200_000
                withAsync (queryLSQ ch GetChainPoint) $ \siblingThread -> do
                    queryException <- waitException "query" queryThread
                    expectTypedException
                        "query"
                        (LocalStateQueryTimeout responseTimeout)
                        queryException
                    siblingException <- waitException "sibling" siblingThread
                    expectTypedException
                        "sibling"
                        ConnectionLost
                        siblingException
                    connectionException <-
                        waitException "connection" connectionThread
                    expectTypedException
                        "connection"
                        (LocalStateQueryTimeout responseTimeout)
                        connectionException
                    stopped <-
                        timeout 500_000 $
                            atomically $
                                takeTMVar connectionStopped
                    stopped `shouldBe` Just ()
                    recovered <-
                        monitorLocalStateQueryConnection ch $
                            pure ()
                    recovered `shouldBe` ()

responseTimeout :: Int
responseTimeout = 600_000

terminatingConnectionScenario :: IO ()
terminatingConnectionScenario = do
    ch <- newLSQChannelWithTimeout 1 responseTimeout
    queryAccepted <- newEmptyTMVarIO
    let peer =
            void $
                Stateful.connect
                    StateIdle
                    ( Client.localStateQueryClientPeer $
                        mkLocalStateQueryClient ch
                    )
                    ( localStateQueryServerPeer $
                        liveStalledServer queryAccepted
                    )
        connection =
            monitorLocalStateQueryConnection ch $ do
                atomically $ void $ takeTMVar queryAccepted
                throwIO PeerTerminated
    withAsync peer $ \_ ->
        withAsync connection $ \connectionThread ->
            withAsync
                ( withAcquiredLSQ ch $ \acquired ->
                    queryAcquiredLSQ acquired GetChainPoint
                )
                $ \queryThread -> do
                    connectionException <-
                        waitException "connection" connectionThread
                    expectTypedException
                        "connection"
                        PeerTerminated
                        connectionException
                    generation <-
                        readTVarIO $ lsqLivenessGeneration ch
                    generation `shouldBe` 1
                    queryException <-
                        waitExceptionWithin 500_000 "query" queryThread
                    expectTypedException
                        "query"
                        ConnectionLost
                        queryException

data PeerTerminated = PeerTerminated
    deriving stock (Eq, Show)

instance Exception PeerTerminated

waitException :: String -> Async a -> IO SomeException
waitException = waitExceptionWithin 1_500_000

waitExceptionWithin :: Int -> String -> Async a -> IO SomeException
waitExceptionWithin timeoutMicroseconds label thread = do
    timedResult <- timeout timeoutMicroseconds $ waitCatch thread
    case timedResult of
        Nothing -> fail $ label <> " did not terminate"
        Just result -> fromAsyncResult result
  where
    fromAsyncResult result = case result of
        Left exception -> pure exception
        Right _ -> fail "expected asynchronous action to fail"

expectTypedException ::
    (Exception e, Eq e) =>
    String ->
    e ->
    SomeException ->
    IO ()
expectTypedException label expected exception =
    case fromException exception of
        Just actual -> actual `shouldBe` expected
        Nothing ->
            expectationFailure $
                label
                    <> " raised unexpected exception: "
                    <> displayException exception

stalledServer :: TMVar () -> LocalStateQueryServer block point query IO ()
stalledServer queryAccepted = LocalStateQueryServer $ pure idle
  where
    idle =
        ServerStIdle
            { recvMsgAcquire = \_ -> pure $ SendMsgAcquired acquired
            , recvMsgDone = pure ()
            }
    acquired =
        ServerStAcquired
            { recvMsgQuery = \_ -> do
                atomically $ putTMVar queryAccepted ()
                atomically retry
            , recvMsgReAcquire = \_ -> pure $ SendMsgAcquired acquired
            , recvMsgRelease = pure idle
            }

liveStalledServer ::
    TMVar () -> LocalStateQueryServer block point query IO ()
liveStalledServer queryAccepted =
    LocalStateQueryServer $ pure idle
  where
    idle =
        ServerStIdle
            { recvMsgAcquire = \_ -> pure $ SendMsgAcquired acquired
            , recvMsgDone = pure ()
            }
    acquired =
        ServerStAcquired
            { recvMsgQuery = \_ -> do
                atomically $ putTMVar queryAccepted ()
                threadDelay 5_000_000
                fail "query unexpectedly unblocked"
            , recvMsgReAcquire = \_ -> pure $ SendMsgAcquired acquired
            , recvMsgRelease = pure idle
            }
