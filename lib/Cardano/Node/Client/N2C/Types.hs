{-# LANGUAGE GADTs #-}

{- |
Module      : Cardano.Node.Client.N2C.Types
Description : N2C channel and request types
License     : Apache-2.0

Channel types and request wrappers for communicating
with the Cardano node via the node-to-client
Ouroboros mini-protocols: LocalStateQuery (UTxO and
protocol-parameter queries) and LocalTxSubmission
(signed transaction submission).

Communication is channel-based: callers enqueue
requests into a 'TBQueue' and block on a 'TMVar'
for the result.
-}
module Cardano.Node.Client.N2C.Types (
    -- * Channel types
    LSQChannel (..),
    LTxSChannel (..),

    -- * Request wrappers
    SomeLSQQuery (..),
    TxSubmitRequest (..),

    -- * Connection-loss signal
    ConnectionLost (..),
) where

import Control.Concurrent.STM (TBQueue, TMVar)
import Control.Exception (Exception)

import Cardano.Node.Client.Types (Block)
import Ouroboros.Consensus.Ledger.Query (Query)
import Ouroboros.Consensus.Ledger.SupportsMempool (
    ApplyTxErr,
    GenTx,
 )

{- | Existential wrapper for a query with its result
slot, so the protocol loop can serve arbitrary
queries without knowing the result type.
-}
data SomeLSQQuery where
    SomeLSQQuery ::
        Query Block result ->
        TMVar result ->
        SomeLSQQuery

{- | Channel for communicating with the
LocalStateQuery mini-protocol client.

Callers enqueue a 'SomeLSQQuery' and then block
on the embedded 'TMVar' to receive the result.
-}
newtype LSQChannel = LSQChannel
    { lsqRequests :: TBQueue SomeLSQQuery
    }

{- | A transaction submission request bundled with
its response slot.
-}
data TxSubmitRequest = TxSubmitRequest
    { tsrTx :: !(GenTx Block)
    -- ^ The transaction to submit
    , tsrResult ::
        !(TMVar (Either (ApplyTxErr Block) ()))
    -- ^ Where to put the submission result
    }

{- | Channel for communicating with the
LocalTxSubmission mini-protocol client.
-}
newtype LTxSChannel = LTxSChannel
    { ltxsRequests :: TBQueue TxSubmitRequest
    }

{- | Synchronous exception raised by 'queryLSQ' /
'submitTxN2C' when the underlying N2C connection died
mid-request.

Symptom this replaces: GHC throws
'BlockedIndefinitelyOnSTM' to the caller because the
consumer thread held the only reference to the
result 'TMVar', then died with the bearer-close
exception, and GC observed no remaining writers. By
catching that synchronous-detected deadlock here and
re-raising 'ConnectionLost' instead, callers see a
typed exception they can handle (e.g. surface
@no-pickable-source@ / @index-not-ready@ to the
composer and exit 1 for a retry on the next tick),
and the daemon process stays alive while the
reconnect supervisor reopens the bearer.
-}
data ConnectionLost = ConnectionLost
    deriving stock (Eq, Show)

instance Exception ConnectionLost
