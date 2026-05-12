{- |
Module      : Cardano.Node.Client.N2C.LocalStateQuery
Description : LocalStateQuery protocol client
License     : Apache-2.0

Channel-driven LocalStateQuery client. On each
iteration: waits for a query on the 'LSQChannel',
acquires the volatile tip, serves the request, then
releases and loops. One-shot requests queued behind
another one-shot request can still be served in the
same acquired state, but explicit acquired sessions
always begin from their own acquire.
-}
module Cardano.Node.Client.N2C.LocalStateQuery (
    -- * Client construction
    mkLocalStateQueryClient,

    -- * Query helpers
    queryLSQ,
    withAcquiredLSQ,
    queryAcquiredLSQ,
) where

import Cardano.Node.Client.N2C.Types (
    AcquiredLSQ (..),
    AcquiredLSQRequest (..),
    ConnectionLost (..),
    LSQChannel (..),
    LSQRequest (..),
    SomeLSQQuery (..),
 )
import Cardano.Node.Client.Types (
    Block,
    BlockPoint,
 )
import Control.Concurrent.STM (
    TMVar,
    atomically,
    newEmptyTMVarIO,
    newTBQueueIO,
    putTMVar,
    readTBQueue,
    takeTMVar,
    tryReadTBQueue,
    writeTBQueue,
 )
import Control.Exception (
    BlockedIndefinitelyOnSTM,
    SomeException,
    catch,
    handle,
    mask,
    onException,
    throwIO,
 )
import Control.Monad (void)
import Numeric.Natural (Natural)
import Ouroboros.Consensus.Ledger.Query (Query)
import Ouroboros.Network.Protocol.LocalStateQuery.Client (
    ClientStAcquired (..),
    ClientStAcquiring (..),
    ClientStIdle (..),
    ClientStQuerying (..),
    LocalStateQueryClient (..),
 )
import Ouroboros.Network.Protocol.LocalStateQuery.Type (
    Target (..),
 )
import System.Timeout (timeout)

{- | Per-session command queue capacity.

Acquired-session callbacks normally issue queries
sequentially. The bound still allows a small amount
of callback-local concurrency while applying
back-pressure instead of letting leaked handles grow
memory without limit.
-}
acquiredLSQQueueCapacity :: Natural
acquiredLSQQueueCapacity = 16

{- | Build a 'LocalStateQueryClient' driven by the
given channel. The client loops: wait for a query,
acquire volatile tip, drain the queue, release,
repeat.
-}
mkLocalStateQueryClient ::
    LSQChannel ->
    LocalStateQueryClient
        Block
        BlockPoint
        (Query Block)
        IO
        ()
mkLocalStateQueryClient ch =
    LocalStateQueryClient $ waitAndAcquire ch

{- | Wait for a query to arrive, then acquire the
volatile tip so we always get fresh state.
-}
waitAndAcquire ::
    LSQChannel ->
    IO
        ( ClientStIdle
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
waitAndAcquire ch = do
    -- Block until at least one query arrives
    req <- atomically $ readTBQueue (lsqRequests ch)
    acquireAndServe ch req

-- | Acquire the volatile tip for a specific request.
acquireAndServe ::
    LSQChannel ->
    LSQRequest ->
    IO
        ( ClientStIdle
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
acquireAndServe ch req =
    pure $
        SendMsgAcquire
            VolatileTip
            ClientStAcquiring
                { recvMsgAcquired =
                    serveRequest ch req
                , recvMsgFailure = \_failure ->
                    waitAndAcquire ch
                }

-- | Serve an acquired request.
serveRequest ::
    LSQChannel ->
    LSQRequest ->
    IO
        ( ClientStAcquired
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
serveRequest ch (LSQOneShot query) =
    serveQuery ch query
serveRequest ch (LSQAcquire acquired acquiredVar) =
    serveAcquired ch acquired acquiredVar

-- | Serve a single query, then check for more.
serveQuery ::
    LSQChannel ->
    SomeLSQQuery ->
    IO
        ( ClientStAcquired
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
serveQuery ch (SomeLSQQuery query resultVar) =
    pure $
        SendMsgQuery
            query
            ClientStQuerying
                { recvMsgResult = \result -> do
                    atomically $
                        putTMVar resultVar result
                    -- Try to drain more queries
                    -- before releasing
                    mNext <-
                        atomically $
                            tryReadTBQueue
                                (lsqRequests ch)
                    case mNext of
                        Just (LSQOneShot next) ->
                            serveQuery ch next
                        Just next ->
                            pure $
                                SendMsgRelease $
                                    acquireAndServe ch next
                        Nothing ->
                            -- No more; release and
                            -- wait for next batch
                            pure $
                                SendMsgRelease $
                                    waitAndAcquire ch
                }

-- | Serve commands from an acquired-session queue.
serveAcquired ::
    LSQChannel ->
    AcquiredLSQ ->
    TMVar () ->
    IO
        ( ClientStAcquired
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
serveAcquired ch acquired acquiredVar = do
    atomically $ putTMVar acquiredVar ()
    serveAcquiredCommand ch acquired

serveAcquiredCommand ::
    LSQChannel ->
    AcquiredLSQ ->
    IO
        ( ClientStAcquired
            Block
            BlockPoint
            (Query Block)
            IO
            ()
        )
serveAcquiredCommand ch acquired = do
    req <-
        atomically $
            readTBQueue (acquiredLSQRequests acquired)
    case req of
        AcquiredLSQQuery query resultVar ->
            pure $
                SendMsgQuery
                    query
                    ClientStQuerying
                        { recvMsgResult = \result -> do
                            atomically $
                                putTMVar resultVar result
                            serveAcquiredCommand ch acquired
                        }
        AcquiredLSQRelease releaseVar -> do
            atomically $
                putTMVar releaseVar ()
            pure $
                SendMsgRelease $
                    waitAndAcquire ch

{- | Submit a query through the channel and block
until the result is available.
-}
queryLSQ ::
    -- | Channel to the LocalStateQuery client
    LSQChannel ->
    -- | The query to execute
    Query Block result ->
    IO result
queryLSQ ch query = do
    resultVar <- newEmptyTMVarIO
    atomically $
        writeTBQueue (lsqRequests ch) $
            LSQOneShot $
                SomeLSQQuery query resultVar
    takeTMVarOrConnectionLost resultVar

{- | Acquire LocalStateQuery once, run a callback, then
release the acquired session.
-}
withAcquiredLSQ ::
    LSQChannel ->
    (AcquiredLSQ -> IO a) ->
    IO a
withAcquiredLSQ ch action =
    mask $ \restore -> do
        acquired <-
            AcquiredLSQ
                <$> newTBQueueIO acquiredLSQQueueCapacity
        acquiredVar <- newEmptyTMVarIO
        atomically $
            writeTBQueue (lsqRequests ch) $
                LSQAcquire acquired acquiredVar
        takeTMVarOrConnectionLost acquiredVar
        result <-
            restore (action acquired)
                `onException` releaseAcquiredLSQBestEffort acquired
        releaseAcquiredLSQ acquired
        pure result

{- | Submit a query through an acquired session and
block until the result is available.
-}
queryAcquiredLSQ ::
    AcquiredLSQ ->
    Query Block result ->
    IO result
queryAcquiredLSQ acquired query = do
    resultVar <- newEmptyTMVarIO
    atomically $
        writeTBQueue
            (acquiredLSQRequests acquired)
            (AcquiredLSQQuery query resultVar)
    takeTMVarOrConnectionLost resultVar

releaseAcquiredLSQ ::
    AcquiredLSQ ->
    IO ()
releaseAcquiredLSQ acquired = do
    releaseVar <- newEmptyTMVarIO
    atomically $
        writeTBQueue
            (acquiredLSQRequests acquired)
            (AcquiredLSQRelease releaseVar)
    void $
        takeTMVarOrConnectionLost releaseVar

releaseAcquiredLSQBestEffort ::
    AcquiredLSQ ->
    IO ()
releaseAcquiredLSQBestEffort acquired =
    void (timeout 1000000 (releaseAcquiredLSQ acquired))
        `catch` \(_ :: SomeException) -> pure ()

takeTMVarOrConnectionLost ::
    TMVar a ->
    IO a
takeTMVarOrConnectionLost resultVar =
    -- Catch the synchronous-deadlock detection that GHC
    -- raises when the consumer thread died with this
    -- request in flight, and re-raise 'ConnectionLost' so
    -- callers see a typed, recoverable exception. The
    -- reconnect supervisor will reopen the bearer.
    handle
        (\(_ :: BlockedIndefinitelyOnSTM) -> throwIO ConnectionLost)
        (atomically $ takeTMVar resultVar)
