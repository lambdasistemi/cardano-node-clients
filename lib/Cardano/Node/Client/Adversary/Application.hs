{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use const" #-}
module Cardano.Node.Client.Adversary.Application (
    Limit (..),
    adversaryApplication,
    ChainSyncApplication,
    repeatedAdversaryApplication,
)
where

import Cardano.Network.NodeToNode (
    ControlMessage (..),
    ControlMessageSTM,
 )
import Cardano.Node.Client.Adversary.ChainSync.Codec (Header, Point, Tip)
import Cardano.Node.Client.Adversary.ChainSync.Connection (
    ChainSyncApplication,
    runChainSyncApplication,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    mapConcurrently_,
 )
import Control.Concurrent.Class.MonadSTM.Strict (
    MonadSTM (..),
    StrictTVar,
    modifyTVar,
    newTVarIO,
    readTVar,
 )
import Control.Exception (SomeException, try)
import Control.Tracer (Tracer, traceWith)
import Data.Function (fix)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Word (Word32)
import Network.Socket (PortNumber)
import Ouroboros.Consensus.Block (headerPoint)
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block (genesisPoint, getTipPoint)
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Protocol.ChainSync.Client (
    ChainSyncClient (..),
    ClientStIdle (..),
    ClientStIntersect (..),
    ClientStNext (..),
 )

newtype State = State
    { chainVar :: StrictTVar IO SyncedChain
    }

type SyncedChain = [Header]

onChainVar :: State -> (SyncedChain -> SyncedChain) -> IO ()
onChainVar state f = atomically $ modifyTVar (chainVar state) f

readChainVar :: State -> STM IO SyncedChain
readChainVar state = readTVar $ chainVar state

readChainVarIO :: State -> IO SyncedChain
readChainVarIO = atomically . readChainVar

rollForward :: State -> Header -> IO ()
rollForward state b = onChainVar state $ \(!chain) ->
    chain <> [b]

-- We will fail to roll back iff `p` doesn't exist in `chain`
-- This will happen when we're asked to roll back to `startingPoint`,
-- which we can check for, or any point before, which we can't
-- check for. Hence we ignore all failures to rollback and replace the
-- chain with an empty one if we do.
rollBackward :: State -> Point -> IO ()
rollBackward state p = onChainVar state $ \(!chain) ->
    rollbackToPoint p chain

rollbackToPoint :: Point -> SyncedChain -> SyncedChain
rollbackToPoint p
    | p == genesisPoint = const []
    | otherwise = go []
  where
    go _ [] = []
    go kept (h : hs)
        | headerPoint h == p = reverse (h : kept)
        | otherwise = go (h : kept) hs

headPoint :: SyncedChain -> Point
headPoint [] = genesisPoint
headPoint chain = headerPoint (last chain)

-- | A limit on the number of blocks to sync
newtype Limit = Limit {limit :: Word32}
    deriving newtype (Show, Read, Eq, Ord)

-- the way to step the protocol
type StepProtocol = IO (Maybe Protocol)

-- Internal protocol state machine
data Protocol = Protocol
    { onRollBackward :: Point -> Tip -> StepProtocol
    , onRollForward :: Header -> StepProtocol
    , points :: [Point] -> StepProtocol
    }

-- A protocol controlled by control messages
controlledProtocol ::
    ControlMessageSTM IO -> -- control message source
    Protocol
controlledProtocol controlMessageSTM = fix $ \client ->
    let react ctrl = case ctrl of
            Continue -> Just client
            Quiesce -> error "controlledClient: unexpected Quiesce"
            Terminate -> Nothing
     in Protocol
            { onRollBackward = \_point _tip ->
                react <$> atomically controlMessageSTM
            , onRollForward = \_header ->
                react <$> atomically controlMessageSTM
            , points = \_points -> pure $ Just client
            }

-- a control message source that terminates after syncing 'limit' blocks
terminateAfterCount ::
    State ->
    Limit ->
    ControlMessageSTM IO
terminateAfterCount stateVar limit = do
    chainLength <-
        Limit . fromIntegral . length <$> readChainVar stateVar
    pure $
        if chainLength < limit
            then Continue
            else Terminate

-- initialize the protocol with a control message source
mkProtocol ::
    State -> -- the mock chain
    Limit -> -- limit of blocks to sync
    Protocol
mkProtocol stateVar limit =
    controlledProtocol $ terminateAfterCount stateVar limit

-- The idle state of the chain sync client
type ChainSyncIdle = ClientStIdle Header Point Tip IO ()

-- when the protocols returns Nothing, we're done as a N2N client
nothingToDone ::
    Maybe Protocol ->
    (Protocol -> ChainSyncIdle) ->
    ChainSyncIdle
nothingToDone Nothing _ = SendMsgDone ()
nothingToDone (Just next) cont = cont next

-- boots the protocol and step into initialise
mkChainSyncApplication ::
    -- | the mock chain
    State ->
    -- | starting point
    Point ->
    -- | limit of blocks to sync
    Limit ->
    -- | the chain sync client application
    ChainSyncApplication
mkChainSyncApplication stateVar startingPoint limit = ChainSyncClient $ do
    ps <- points (mkProtocol stateVar limit) [startingPoint]
    pure $ nothingToDone ps $ initialise stateVar startingPoint

-- In this consumer example, we do not care about whether the server
-- found an intersection or not. If not, we'll just sync from genesis.
--
-- Alternative policies here include:
--  iteratively finding the best intersection
--  rejecting the server if there is no intersection in the last K blocks
--
initialise ::
    State -> -- the mock chain
    Point -> -- starting point
    Protocol -> -- previous client state machine
    ChainSyncIdle
initialise stateVar startingPoint prev =
    let next =
            ChainSyncClient
                { runChainSyncClient = pure $ requestNext stateVar prev
                }
     in SendMsgFindIntersect [startingPoint] $
            ClientStIntersect
                { recvMsgIntersectFound = \_point _tip -> next
                , recvMsgIntersectNotFound = \_tip -> next
                }

requestNext ::
    State -> -- the mock chain
    Protocol -> -- this client state machine
    ChainSyncIdle
requestNext stateVar prev =
    SendMsgRequestNext
        (pure ())
        ClientStNext
            { recvMsgRollForward = \header tip -> ChainSyncClient $ do
                rollForward stateVar header
                choice <-
                    stoppingOnTip
                        (headerPoint header)
                        (getTipPoint tip)
                        $ onRollForward prev header
                pure $ nothingToDone choice $ requestNext stateVar
            , recvMsgRollBackward = \pIntersect tip -> ChainSyncClient $ do
                rollBackward stateVar pIntersect
                choice <- onRollBackward prev pIntersect tip
                pure $ nothingToDone choice $ requestNext stateVar
            }

stoppingOnTip ::
    (Ord a) =>
    a ->
    a ->
    StepProtocol ->
    StepProtocol
stoppingOnTip h t stepProtocol
    | h >= t = pure Nothing
    | otherwise = stepProtocol

{- | Run an adversary application that connects to a node and syncs
blocks starting from the given point, up to the given limit.
-}
adversaryApplication ::
    -- | network magic
    NetworkMagic ->
    -- | peer host
    String ->
    -- | peer port
    PortNumber ->
    -- | starting point
    Point ->
    -- | limit of blocks to sync
    Limit ->
    IO (Either SomeException Point)
adversaryApplication magic peerName peerPort startingPoint limit = do
    chainVar <- newTVarIO ([] :: SyncedChain)
    let stateVar = State{chainVar}
    res <-
        -- To gracefully handle the node getting killed it seems we need
        -- the outer 'try', even if connectToNode already returns 'Either
        -- SomeException'.
        try $
            runChainSyncApplication
                magic
                peerName
                peerPort
                (const $ mkChainSyncApplication stateVar startingPoint limit)
    case res of
        Left e -> return $ Left e
        Right _ -> pure . headPoint <$> readChainVarIO stateVar

repeatedAdversaryApplication ::
    Tracer IO String -> -- thread safe logger
    Int ->
    NetworkMagic ->
    [String] ->
    PortNumber ->
    -- | must be infinite list
    NonEmpty Point ->
    Limit ->
    IO ()
repeatedAdversaryApplication tracer nConns magic peerNames peerPort startingPoints limit = do
    let write = traceWith tracer
    let singleRun (_i, peerName, startingPoint) = do
            write $
                "Starting adversary application against "
                    <> peerName
                    <> " from point "
                    <> show startingPoint
            result <-
                (startingPoint,)
                    <$> adversaryApplication magic peerName peerPort startingPoint limit
            write $
                "Completed adversary application against "
                    <> peerName
                    <> " from point "
                    <> show startingPoint
                    <> " with result "
                    <> show result
    mapConcurrently_
        singleRun
        $ zip3 [1 .. nConns] (cycle peerNames) (NE.toList startingPoints)
    threadDelay 1000000 -- wait for logging to complete
