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
    monitorLocalStateQueryPeer,
    queryAcquiredLSQ,
    queryLSQ,
    withAcquiredLSQ,
 )
import Cardano.Node.Client.N2C.Types (
    ConnectionLost (..),
    LocalStateQueryTimeout (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, waitCatch, withAsync)
import Control.Concurrent.STM (
    TMVar,
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    retry,
    takeTMVar,
 )
import Control.Exception (
    Exception,
    SomeException,
    displayException,
    fromException,
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
spec = describe "Cardano.Node.Client.N2C.LocalStateQuery" $
    it "bounds a stalled acquired query" $ do
        result <- timeout 2_000_000 stalledQueryScenario
        result `shouldBe` Just ()

stalledQueryScenario :: IO ()
stalledQueryScenario = do
    ch <- newLSQChannelWithTimeout 2 responseTimeout
    peerStarted <- newEmptyTMVarIO
    queryAccepted <- newEmptyTMVarIO
    let peer =
            monitorLocalStateQueryPeer ch $
                atomically (putTMVar peerStarted ())
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
    withAsync peer $ \peerThread -> do
        atomically $ void $ takeTMVar peerStarted
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
                    peerException <- waitException "peer" peerThread
                    expectTypedException
                        "peer"
                        (LocalStateQueryTimeout responseTimeout)
                        peerException

responseTimeout :: Int
responseTimeout = 600_000

waitException :: String -> Async a -> IO SomeException
waitException label thread = do
    timedResult <- timeout 1_500_000 $ waitCatch thread
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
