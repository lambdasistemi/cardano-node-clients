{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Daemon
Description : tx-generator daemon — wires N2C, indexer, server
License     : Apache-2.0

Composes the four pieces the daemon needs:

* the in-memory address-to-UTxO indexer from
  @utxo-indexer-lib@ (the @withInMemoryIndexer@ /
  @withRocksDBIndexer@ surface),

* a single N2C connection to the relay via
  'Cardano.Node.Client.N2C.Connection.runNodeClientFull'
  carrying ChainSync (feeds the indexer), LSQ (one-shot
  PParams query at startup), and LTxS (used by future
  transact / refill arms),

* the NDJSON control wire from
  'Cardano.Node.Client.TxGenerator.Server',

* the on-disk state from
  'Cardano.Node.Client.TxGenerator.Persist' (@master.seed@
  + @next-hd-index@).

The chain-sync follower glue (@Intersector@ / @Follower@)
mirrors the merged indexer's @Daemon.hs@ pattern,
re-implemented here so the indexer's internals stay
private.

T007 ships only the @ready@ / @snapshot@ readonly hooks
real; @transact@ and @refill@ are stubbed at the server
level (see 'Cardano.Node.Client.TxGenerator.Server.stubHooks')
until T008 / T011.
-}
module Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClientFull,
 )
import Cardano.Node.Client.TxGenerator.Persist (
    loadOrCreateSeed,
    nextHDIndexPath,
    readNextHDIndex,
 )
import Cardano.Node.Client.TxGenerator.Server (
    runServer,
    stubHooks,
 )
import Cardano.Node.Client.TxGenerator.Types (
    ReadyResponse (..),
    SnapshotResponse (..),
 )
import Cardano.Node.Client.UTxOIndexer.BlockExtract (extractBlock)
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    withInMemoryIndexer,
    withRocksDBIndexer,
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
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Word (Word32, Word64)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.Directory (createDirectoryIfMissing)

-- | Daemon runtime configuration.
data DaemonConfig = DaemonConfig
    { dcRelaySocket :: !FilePath
    , dcControlSocket :: !FilePath
    , dcStateDir :: !FilePath
    , dcMasterSeedFile :: !FilePath
    , dcFaucetSKeyFile :: !FilePath
    , dcNetworkMagic :: !Word32
    , dcByronEpochSlots :: !Word64
    , dcAwaitTimeoutSeconds :: !Int
    , dcReadyThresholdSlots :: !Word64
    , dcSecurityParamK :: !Int
    , dcDbPath :: !(Maybe FilePath)
    }
    deriving stock (Show)

{- | Mirrors the indexer's per-run readiness state. Filled
in by the chain-sync follower; read by the @ready@
endpoint.
-}
data ReadyState = ReadyState
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe Word64)
    , rsProcessedSlot :: !(Maybe Word64)
    }
    deriving stock (Show)

initialReady :: ReadyState
initialReady =
    ReadyState
        { rsReady = False
        , rsTipSlot = Nothing
        , rsProcessedSlot = Nothing
        }

{- | Boot classification: cold (no retained rollback
points) vs. warm (retained from a prior run). Mirrors
the indexer daemon's 'BootMode'.
-}
data BootMode
    = ColdBoot
    | WarmBoot ![(SlotNo, BlockHash)]

{- | Open the indexer (in-memory if @dcDbPath@ is
'Nothing', RocksDB otherwise), open one N2C connection
to the relay carrying chain-sync + LSQ + LTxS, mount the
control wire on @dcControlSocket@, and block until the
chain-sync side or the server exits.
-}
runDaemon :: DaemonConfig -> IO ()
runDaemon cfg = do
    createDirectoryIfMissing True (dcStateDir cfg)
    -- Master seed (created on first run, idempotent
    -- thereafter). We don't use it on the tx path in
    -- T007; this is just sanity that the file exists
    -- and is well-formed.
    _masterSeed <- loadOrCreateSeed (dcMasterSeedFile cfg)
    -- Faucet skey is loaded but not yet consumed by T007.
    _faucetKeyBytes <- BS.readFile (dcFaucetSKeyFile cfg)
    withIndexer (dcDbPath cfg) $ \idx -> do
        readyVar <- newTVarIO initialReady
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        bootMode <- detectBootMode idx
        let resumePoints = case bootMode of
                ColdBoot ->
                    [Network.Point Network.Point.Origin]
                WarmBoot ps -> fmap toHeaderPoint ps
            chainSyncApp =
                mkChainSyncN2C
                    nullTracer
                    nullTracer
                    (mkIntersector bootMode cfg readyVar idx)
                    resumePoints
            nodeAction =
                runNodeClientFull
                    (NetworkMagic (dcNetworkMagic cfg))
                    (EpochSlots (dcByronEpochSlots cfg))
                    (dcRelaySocket cfg)
                    chainSyncApp
                    lsqCh
                    ltxsCh
        let getReady = readyResponseFrom readyVar
            getSnapshot =
                snapshotResponseFrom
                    (nextHDIndexPath (dcStateDir cfg))
                    readyVar
            hooks = stubHooks getReady getSnapshot
            serverAction = runServer (dcControlSocket cfg) hooks
        -- One physical N2C connection (chain-sync feeds the
        -- indexer; LSQ + LTxS are open and idle for T008+
        -- to consume); run it concurrently with the server.
        concurrently_ (void nodeAction) serverAction
  where
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) = withRocksDBIndexer path

-- ----------------------------------------------------------------------
-- Server hooks
-- ----------------------------------------------------------------------

readyResponseFrom :: TVar ReadyState -> IO ReadyResponse
readyResponseFrom readyVar = do
    rs <- readTVarIO readyVar
    pure
        ReadyResponse
            { readyReady = rsReady rs
            , readyIndexReady = rsReady rs
            , -- T007: faucet UTxOs are not yet checked;
              -- T008 wires this.
              readyFaucetUtxosKnown = False
            }

snapshotResponseFrom ::
    FilePath ->
    TVar ReadyState ->
    IO SnapshotResponse
snapshotResponseFrom indexPath readyVar = do
    nextIdx <- readNextHDIndex indexPath
    rs <- readTVarIO readyVar
    pure
        SnapshotResponse
            { snapPopulationSize = nextIdx
            , -- v1: percentile aggregation lands in T013;
              -- T007's snapshot reports population +
              -- index tip + lastTxId only.
              snapP10Lovelace = Nothing
            , snapP50Lovelace = Nothing
            , snapP90Lovelace = Nothing
            , snapTipSlot = rsTipSlot rs
            , -- T007 doesn't track lastTxId yet; T011 wires
              -- it.
              snapLastTxId = Nothing
            }

-- ----------------------------------------------------------------------
-- Chain-sync follower glue
-- ----------------------------------------------------------------------

detectBootMode :: IndexerHandle -> IO BootMode
detectBootMode idx = do
    pairs <- getResumePoints idx
    pure $ case pairs of
        [] -> ColdBoot
        ps -> WarmBoot ps

toHeaderPoint :: (SlotNo, BlockHash) -> HeaderPoint
toHeaderPoint (SlotNo s, BlockHash bh) =
    Network.Point
        ( Network.Point.At
            ( Network.Point.Block
                (Network.SlotNo s)
                (OneEraHash (SBS.toShort bh))
            )
        )

mkIntersector ::
    BootMode ->
    DaemonConfig ->
    TVar ReadyState ->
    IndexerHandle ->
    Intersector HeaderPoint Network.SlotNo Fetched
mkIntersector bootMode cfg readyVar idx = self
  where
    self =
        Intersector
            { intersectFound = \point -> do
                rollbackTo idx (slotOfPoint point)
                pure (mkFollower cfg readyVar idx)
            , intersectNotFound = case bootMode of
                ColdBoot ->
                    pure
                        ( self
                        , [Network.Point Network.Point.Origin]
                        )
                WarmBoot _ ->
                    error
                        "tx-generator: chain-sync found no \
                        \intersection against any retained \
                        \rollback-log point. Wipe --db-path \
                        \(or --state-dir for the in-memory \
                        \default) to rebuild from Origin."
            }

slotOfPoint :: HeaderPoint -> SlotNo
slotOfPoint p =
    case Network.pointSlot p of
        Network.Point.Origin -> SlotNo 0
        Network.Point.At s -> SlotNo (Network.unSlotNo s)

mkFollower ::
    DaemonConfig ->
    TVar ReadyState ->
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
                        Network.Point.At s ->
                            SlotNo (Network.unSlotNo s)
                rollbackTo idx slot
                pure (Progress self)
            }

pointToBlockHash :: HeaderPoint -> BlockHash
pointToBlockHash p =
    case p of
        Network.Point Network.Point.Origin ->
            BlockHash mempty
        Network.Point
            (Network.Point.At (Network.Point.Block _ h)) ->
                BlockHash (SBS.fromShort (getOneEraHash h))

updateReady ::
    DaemonConfig ->
    TVar ReadyState ->
    SlotNo ->
    Network.SlotNo ->
    IO ()
updateReady cfg readyVar (SlotNo processed) tipNet =
    let tip = Network.unSlotNo tipNet
        behind =
            if tip > processed
                then tip - processed
                else 0
        ready = behind <= dcReadyThresholdSlots cfg
        rs =
            ReadyState
                { rsReady = ready
                , rsTipSlot = Just tip
                , rsProcessedSlot = Just processed
                }
     in atomically (writeTVar readyVar rs)
