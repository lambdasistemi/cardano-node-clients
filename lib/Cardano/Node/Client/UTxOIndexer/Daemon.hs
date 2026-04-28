{- |
Module      : Cardano.Node.Client.UTxOIndexer.Daemon
Description : Daemon entrypoint — wires ChainSync, Indexer, Server
License     : Apache-2.0

Composes the four pieces the daemon needs:

* 'IndexerHandle' from @utxo-indexer-lib@ — the in-memory
  address->UTxO index plus its rollback log and await
  waiters.
* 'Cardano.Node.Client.UTxOIndexer.BlockExtract.extractBlock'
  — block→@(slot, [UtxoOp])@ era-polymorphic decoder.
* 'Cardano.Node.Client.UTxOIndexer.Server.runServer' —
  NDJSON Unix-socket server.
* 'Cardano.Node.Client.N2C.ChainSync.runChainSyncN2C' —
  the chain-sync follower itself.

A 'TVar' 'ReadyStatus' is updated as blocks land so the
@ready@ NDJSON request reflects the daemon's current
catch-up state.
-}
module Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )
import Cardano.Node.Client.UTxOIndexer.BlockExtract (extractBlock)
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    withInMemoryIndexer,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    BlockHash (..),
    SlotNo (..),
 )
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM (
    TVar,
    atomically,
    newTVarIO,
    readTVarIO,
    writeTVar,
 )
import Control.Monad (void)
import Control.Tracer (nullTracer)
import Data.ByteString.Short qualified as SBS
import Data.Word (Word32, Word64)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point

{- | Daemon runtime configuration. Plain Haskell record;
the CLI-parsing in @Main@ produces this.
-}
data DaemonConfig = DaemonConfig
    { dcRelaySocket :: FilePath
    , dcListenSocket :: FilePath
    , dcNetworkMagic :: Word32
    , dcByronEpochSlots :: Word64
    , dcReadyThresholdSlots :: Word64
    , dcSecurityParamK :: Int
    -- ^ Cardano security parameter @k@ — the
    -- rollback-log entry count is capped at this many,
    -- and older entries are dropped after each apply.
    , dcDbPath :: Maybe FilePath
    -- ^ When 'Just', open the indexer against a RocksDB
    -- database at this path; state survives process
    -- restart. When 'Nothing', use the volatile
    -- in-memory backend (intended for tests).
    }
    deriving stock (Show)

{- | Open the indexer (RocksDB if @dcDbPath@ is set,
in-memory otherwise), start the NDJSON server and the
chain-sync follower, and block. Returns when either side
exits (chain-sync disconnect, server crash, etc.) — the
caller is expected to supervise.
-}
runDaemon :: DaemonConfig -> IO ()
runDaemon cfg = do
    readyVar <- newTVarIO initialReady
    withIndexer (dcDbPath cfg) $ \idx -> do
        let getReady = readTVarIO readyVar
            chainAction =
                runChainSyncN2C
                    (EpochSlots (dcByronEpochSlots cfg))
                    (NetworkMagic (dcNetworkMagic cfg))
                    (dcRelaySocket cfg)
                    ( mkChainSyncN2C
                        nullTracer
                        nullTracer
                        (mkIntersector cfg readyVar idx)
                        [Network.Point Network.Point.Origin]
                    )
            serverAction = runServer (dcListenSocket cfg) idx getReady
        concurrently_ (void chainAction) serverAction
  where
    initialReady =
        ReadyStatus
            { rsReady = False
            , rsTipSlot = Nothing
            , rsProcessedSlot = Nothing
            , rsSlotsBehind = Nothing
            }
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) = withRocksDBIndexer path

mkIntersector ::
    DaemonConfig ->
    TVar ReadyStatus ->
    IndexerHandle ->
    Intersector HeaderPoint Network.SlotNo Fetched
mkIntersector cfg readyVar idx =
    Intersector
        { intersectFound = \_pt -> pure (mkFollower cfg readyVar idx)
        , intersectNotFound =
            pure
                ( mkIntersector cfg readyVar idx
                , [Network.Point Network.Point.Origin]
                )
        }

mkFollower ::
    DaemonConfig ->
    TVar ReadyStatus ->
    IndexerHandle ->
    Follower HeaderPoint Network.SlotNo Fetched
mkFollower cfg readyVar idx = self
  where
    self =
        Follower
            { rollForward = \fetched tip -> do
                let (slot, ops) = extractBlock (fetchedBlock fetched)
                    bh = pointToBlockHash (fetchedPoint fetched)
                applyAtSlot idx slot bh ops
                _ <- pruneRollbacks idx (dcSecurityParamK cfg)
                updateReady cfg readyVar slot tip
                pure self
            , rollBackward = \point -> do
                let slot = case Network.pointSlot point of
                        Network.Point.Origin -> SlotNo 0
                        Network.Point.At s -> SlotNo (Network.unSlotNo s)
                rollbackTo idx slot
                pure (Progress self)
            }

{- | Pull the block hash bytes out of an
'OneEraHash'-shaped 'HeaderPoint'. Origin (no block)
maps to an empty 'BlockHash'.
-}
pointToBlockHash :: HeaderPoint -> BlockHash
pointToBlockHash p =
    case p of
        Network.Point Network.Point.Origin -> BlockHash mempty
        Network.Point (Network.Point.At (Network.Point.Block _ h)) ->
            BlockHash (SBS.fromShort (getOneEraHash h))

updateReady ::
    DaemonConfig ->
    TVar ReadyStatus ->
    SlotNo ->
    Network.SlotNo ->
    IO ()
updateReady cfg readyVar (SlotNo processed) tipNet =
    let tip = Network.unSlotNo tipNet
        behind = if tip > processed then tip - processed else 0
        ready = behind <= dcReadyThresholdSlots cfg
        rs =
            ReadyStatus
                { rsReady = ready
                , rsTipSlot = Just (SlotNo tip)
                , rsProcessedSlot = Just (SlotNo processed)
                , rsSlotsBehind = Just behind
                }
     in atomically (writeTVar readyVar rs)
