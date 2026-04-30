{- |
Module      : Cardano.Node.Client.N2C.LocalTxSubmission
Description : LocalTxSubmission protocol client
License     : Apache-2.0

Channel-driven LocalTxSubmission client. Reads
'TxSubmitRequest' values from the 'LTxSChannel'
queue, submits each to the node, and delivers
the accept\/reject result via the request's 'TMVar'.
-}
module Cardano.Node.Client.N2C.LocalTxSubmission (
    -- * Client construction
    mkLocalTxSubmissionClient,

    -- * Submit helper
    submitTxN2C,
) where

import Cardano.Node.Client.N2C.Types (
    ConnectionLost (..),
    LTxSChannel (..),
    TxSubmitRequest (..),
 )
import Cardano.Node.Client.Types (Block)
import Control.Concurrent.STM (
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTBQueue,
    takeTMVar,
    writeTBQueue,
 )
import Control.Exception (
    BlockedIndefinitelyOnSTM,
    handle,
    throwIO,
 )
import Ouroboros.Consensus.Ledger.SupportsMempool (
    ApplyTxErr,
    GenTx,
 )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client (
    LocalTxClientStIdle (..),
    LocalTxSubmissionClient (..),
    SubmitResult (..),
 )

{- | Build a 'LocalTxSubmissionClient' driven by the
given channel. The client loops: wait for a tx,
submit, deliver result, repeat.
-}
mkLocalTxSubmissionClient ::
    LTxSChannel ->
    LocalTxSubmissionClient
        (GenTx Block)
        (ApplyTxErr Block)
        IO
        ()
mkLocalTxSubmissionClient ch =
    LocalTxSubmissionClient $ clientIdle ch

-- | Idle state: wait for a request, submit it.
clientIdle ::
    LTxSChannel ->
    IO
        ( LocalTxClientStIdle
            (GenTx Block)
            (ApplyTxErr Block)
            IO
            ()
        )
clientIdle ch = do
    TxSubmitRequest{tsrTx = tx, tsrResult = resultVar} <-
        atomically $ readTBQueue (ltxsRequests ch)
    pure $
        SendMsgSubmitTx tx $
            \submitResult -> do
                let result = case submitResult of
                        SubmitSuccess -> Right ()
                        SubmitFail reason -> Left reason
                atomically $ putTMVar resultVar result
                clientIdle ch

{- | Submit a transaction through the channel and
block until the result is available.

Re-raises 'ConnectionLost' instead of letting GHC's
'BlockedIndefinitelyOnSTM' escape when the consumer
thread dies with the request in flight (bearer
closed mid-submit). The reconnect supervisor will
reopen the bearer; callers should treat
'ConnectionLost' as transient and retry.
-}
submitTxN2C ::
    -- | Channel to the LocalTxSubmission client
    LTxSChannel ->
    -- | Generalized transaction to submit
    GenTx Block ->
    IO (Either (ApplyTxErr Block) ())
submitTxN2C ch tx = do
    resultVar <- newEmptyTMVarIO
    atomically $
        writeTBQueue (ltxsRequests ch) $
            TxSubmitRequest
                { tsrTx = tx
                , tsrResult = resultVar
                }
    handle
        (\(_ :: BlockedIndefinitelyOnSTM) -> throwIO ConnectionLost)
        (atomically $ takeTMVar resultVar)
