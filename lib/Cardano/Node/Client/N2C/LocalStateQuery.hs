{- |
Module      : Cardano.Node.Client.N2C.LocalStateQuery
Description : LocalStateQuery protocol client
License     : Apache-2.0

Channel-driven LocalStateQuery client. On each
iteration: waits for a query on the 'LSQChannel',
acquires the volatile tip, drains all queued queries
(batching them in a single acquired session), then
releases and loops. This avoids re-acquiring for
rapid-fire queries.
-}
module Cardano.Node.Client.N2C.LocalStateQuery (
    -- * Client construction
    mkLocalStateQueryClient,

    -- * Query helpers
    queryLSQ,
) where

import Cardano.Node.Client.N2C.Types (
    ConnectionLost (..),
    LSQChannel (..),
    SomeLSQQuery (..),
 )
import Cardano.Node.Client.Types (
    Block,
    BlockPoint,
 )
import Control.Concurrent.STM (
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTBQueue,
    takeTMVar,
    tryReadTBQueue,
    writeTBQueue,
 )
import Control.Exception (
    BlockedIndefinitelyOnSTM,
    handle,
    throwIO,
 )
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
    -- Now acquire the latest volatile tip
    pure $
        SendMsgAcquire
            VolatileTip
            ClientStAcquiring
                { recvMsgAcquired =
                    serveQuery ch req
                , recvMsgFailure = \_failure ->
                    waitAndAcquire ch
                }

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
                        Just next ->
                            serveQuery ch next
                        Nothing ->
                            -- No more; release and
                            -- wait for next batch
                            pure $
                                SendMsgRelease $
                                    waitAndAcquire ch
                }

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
            SomeLSQQuery query resultVar
    -- Catch the synchronous-deadlock detection that GHC
    -- raises when the consumer thread died with this
    -- request in flight, and re-raise 'ConnectionLost' so
    -- callers see a typed, recoverable exception. The
    -- reconnect supervisor will reopen the bearer.
    handle
        (\(_ :: BlockedIndefinitelyOnSTM) -> throwIO ConnectionLost)
        (atomically $ takeTMVar resultVar)
