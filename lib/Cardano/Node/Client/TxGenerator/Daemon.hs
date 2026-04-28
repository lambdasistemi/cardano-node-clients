{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Daemon
Description : tx-generator daemon — wires N2C, indexer, server
License     : Apache-2.0

Composes the four pieces the daemon needs:

* the in-memory address-to-UTxO indexer from
  @utxo-indexer-lib@,

* a single N2C connection to the relay via
  'Cardano.Node.Client.N2C.Connection.runNodeClientFull'
  carrying ChainSync (feeds the indexer), LSQ (one-shot
  PParams query at startup, plus faucet UTxO selection
  on the rare refill path), and LTxS (transaction
  submission),

* the NDJSON control wire from
  'Cardano.Node.Client.TxGenerator.Server',

* the on-disk state from
  'Cardano.Node.Client.TxGenerator.Persist'.

T008 wires the @refill@ arm end-to-end (User Story 2).
@transact@ stays stubbed until T011.
-}
module Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Crypto.DSIGN (
    DSIGNAlgorithm (deriveVerKeyDSIGN),
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (PParams)
import Cardano.Ledger.Api.Tx (
    addrTxWitsL,
    txIdTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Mainnet, Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TxOut, extractHash)
import Cardano.Ledger.Keys (
    VKey (..),
    WitVKey (..),
    asWitness,
    signedDSIGN,
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Node.Client.Ledger (ConwayTx)
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
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxGenerator.Build (refillTx)
import Cardano.Node.Client.TxGenerator.Persist (
    loadOrCreateSeed,
    nextHDIndexPath,
    readNextHDIndex,
    writeNextHDIndex,
 )
import Cardano.Node.Client.TxGenerator.Population (
    deriveAddr,
    enterpriseAddrFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.TxGenerator.Server (
    ServerHooks (..),
    runServer,
 )
import Cardano.Node.Client.TxGenerator.Types (
    FailureReason (..),
    ReadyResponse (..),
    RefillRequest,
    RefillResponse (..),
    SnapshotResponse (..),
    TransactResponse (TransactFail),
 )
import Cardano.Node.Client.UTxOIndexer.BlockExtract (extractBlock)
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AwaitObservation,
    IndexerHandle (..),
    withInMemoryIndexer,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Idx
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (
    MVar,
    modifyMVar,
    newMVar,
 )
import Control.Concurrent.STM (
    TVar,
    atomically,
    newTVarIO,
    readTVarIO,
    writeTVar,
 )
import Control.Monad (void)
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Function (on)
import Data.List (maximumBy)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Word (Word16, Word32, Word64)
import Lens.Micro ((%~), (&), (^.))
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

-- | Mirrors the indexer's per-run readiness state.
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

data BootMode
    = ColdBoot
    | WarmBoot ![(Idx.SlotNo, Idx.BlockHash)]

{- | Default refill amount (lovelace) per @refill@ trigger:
5 000 ADA. Sized to support several K=8 fan-outs at the
protocol minimum-UTxO threshold without immediate
re-refill pressure.
-}
defaultRefillLovelace :: Coin
defaultRefillLovelace = Coin 5_000_000_000

{- | Open the indexer (in-memory if @dcDbPath@ is
'Nothing', RocksDB otherwise), open one N2C connection
to the relay carrying chain-sync + LSQ + LTxS, query
protocol parameters once at startup, mount the control
wire on @dcControlSocket@, and block until the chain-sync
side or the server exits.
-}
runDaemon :: DaemonConfig -> IO ()
runDaemon cfg = do
    createDirectoryIfMissing True (dcStateDir cfg)
    masterSeed <- loadOrCreateSeed (dcMasterSeedFile cfg)
    faucetKeyBytes <- BS.readFile (dcFaucetSKeyFile cfg)
    let faucetSKey = mkSignKey (BS.take 32 faucetKeyBytes)
        net = networkFromMagic (dcNetworkMagic cfg)
        faucetAddr = enterpriseAddrFromSignKey net faucetSKey
    initialIdx <- readNextHDIndex (nextHDIndexPath (dcStateDir cfg))
    nextIdxMVar <- newMVar initialIdx
    withIndexer (dcDbPath cfg) $ \idx -> do
        readyVar <- newTVarIO initialReady
        lastTxIdVar <- newTVarIO Nothing
        faucetKnownVar <- newTVarIO False
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
        withAsync (void nodeAction) $ \_nodeT -> do
            -- Brief settle for the mux handshake.
            threadDelay 3_000_000
            let provider = mkN2CProvider lsqCh
                submitter = mkN2CSubmitter ltxsCh
            pp <- queryProtocolParams provider
            -- Probe the faucet once at startup so the
            -- @ready@ probe can flip @faucetUtxosKnown@
            -- without waiting for the first @refill@
            -- trigger. Subsequent refills update this flag
            -- per their LSQ response.
            initialFaucetUtxos <- queryUTxOs provider faucetAddr
            atomically
                ( writeTVar
                    faucetKnownVar
                    (not (null initialFaucetUtxos))
                )
            let getReady =
                    readyResponseFrom readyVar faucetKnownVar
                getSnapshot =
                    snapshotResponseFrom
                        (nextHDIndexPath (dcStateDir cfg))
                        readyVar
                        lastTxIdVar
                doRefill =
                    runRefillArm
                        cfg
                        pp
                        idx
                        provider
                        submitter
                        net
                        masterSeed
                        faucetSKey
                        faucetAddr
                        nextIdxMVar
                        lastTxIdVar
                        faucetKnownVar
                hooks =
                    ServerHooks
                        { hooksReady = getReady
                        , hooksSnapshot = getSnapshot
                        , hooksTransact = \_ ->
                            pure (TransactFail IndexNotReady)
                        , hooksRefill = doRefill
                        }
            runServer (dcControlSocket cfg) hooks
  where
    withIndexer Nothing = withInMemoryIndexer
    withIndexer (Just path) = withRocksDBIndexer path

-- ----------------------------------------------------------------------
-- Refill arm (User Story 2 / T008)
-- ----------------------------------------------------------------------

{- | Run one refill: take the next-HD-index lock, query
LSQ for the faucet's UTxOs, pick the highest-value one,
build the refill tx, sign with the faucet key, submit,
await the new UTxO at the fresh address via the indexer,
bump and persist the next-HD-index. Releases the lock
on every code path; never increments the index without a
confirmed submit.
-}
runRefillArm ::
    DaemonConfig ->
    PParams ConwayEra ->
    IndexerHandle ->
    Provider IO ->
    Submitter IO ->
    Network ->
    ByteString ->
    SignKeyDSIGN Ed25519DSIGN ->
    Addr ->
    MVar Word64 ->
    TVar (Maybe Text) ->
    TVar Bool ->
    RefillRequest ->
    IO RefillResponse
runRefillArm
    cfg
    pp
    idx
    provider
    submitter
    net
    masterSeed
    faucetSKey
    faucetAddr
    nextIdxMVar
    lastTxIdVar
    faucetKnownVar
    _req =
        modifyMVar nextIdxMVar $ \currentIdx -> do
            utxos <- queryUTxOs provider faucetAddr
            case utxos of
                [] -> do
                    atomically (writeTVar faucetKnownVar False)
                    pure (currentIdx, RefillFail FaucetNotKnown)
                _ -> do
                    atomically (writeTVar faucetKnownVar True)
                    let (faucetIn, faucetOut) =
                            pickHighestValue utxos
                        freshAddr =
                            deriveAddr net masterSeed currentIdx
                        amount = defaultRefillLovelace
                    if faucetOut ^. coinTxOutL <= amount
                        then
                            pure
                                ( currentIdx
                                , RefillFail FaucetExhausted
                                )
                        else
                            buildSignSubmit
                                cfg
                                pp
                                idx
                                submitter
                                faucetSKey
                                faucetAddr
                                (faucetIn, faucetOut)
                                freshAddr
                                amount
                                currentIdx
                                lastTxIdVar

buildSignSubmit ::
    DaemonConfig ->
    PParams ConwayEra ->
    IndexerHandle ->
    Submitter IO ->
    SignKeyDSIGN Ed25519DSIGN ->
    Addr ->
    (TxIn, TxOut ConwayEra) ->
    Addr ->
    Coin ->
    Word64 ->
    TVar (Maybe Text) ->
    IO (Word64, RefillResponse)
buildSignSubmit
    cfg
    pp
    idx
    submitter
    faucetSKey
    faucetAddr
    faucetUtxo
    freshAddr
    amount
    currentIdx
    lastTxIdVar = do
        buildResult <-
            refillTx pp faucetUtxo freshAddr amount faucetAddr
        case buildResult of
            Left err ->
                pure
                    ( currentIdx
                    , RefillFail (SubmitRejected err)
                    )
            Right tx -> do
                let signed = addKeyWitness faucetSKey tx
                result <- submitTx submitter signed
                case result of
                    Rejected reason -> do
                        let reasonText =
                                Text.decodeUtf8With
                                    (\_ _ -> Just '\xFFFD')
                                    reason
                        pure
                            ( currentIdx
                            , RefillFail
                                (SubmitRejected reasonText)
                            )
                    Submitted txId -> do
                        let freshIxn =
                                ledgerToIndexerTxIn txId 0
                            timeoutS =
                                Just (dcAwaitTimeoutSeconds cfg)
                        obs <- awaitTxIn idx freshIxn timeoutS
                        let awaited = isJust (obs :: Maybe AwaitObservation)
                            txHex = txIdToHex txId
                        writeNextHDIndex
                            (nextHDIndexPath (dcStateDir cfg))
                            (currentIdx + 1)
                        atomically
                            ( writeTVar
                                lastTxIdVar
                                (Just txHex)
                            )
                        pure
                            ( currentIdx + 1
                            , RefillOk
                                { rfOkTxId = txHex
                                , rfOkFreshIndex = currentIdx
                                , rfOkValueLovelace = unCoin amount
                                , rfOkAwaited = awaited
                                }
                            )

-- ----------------------------------------------------------------------
-- Server hooks
-- ----------------------------------------------------------------------

readyResponseFrom ::
    TVar ReadyState -> TVar Bool -> IO ReadyResponse
readyResponseFrom readyVar faucetKnownVar = do
    rs <- readTVarIO readyVar
    fk <- readTVarIO faucetKnownVar
    pure
        ReadyResponse
            { readyReady = rsReady rs && fk
            , readyIndexReady = rsReady rs
            , readyFaucetUtxosKnown = fk
            }

snapshotResponseFrom ::
    FilePath ->
    TVar ReadyState ->
    TVar (Maybe Text) ->
    IO SnapshotResponse
snapshotResponseFrom indexPath readyVar lastTxIdVar = do
    nextIdx <- readNextHDIndex indexPath
    rs <- readTVarIO readyVar
    lastTx <- readTVarIO lastTxIdVar
    pure
        SnapshotResponse
            { snapPopulationSize = nextIdx
            , snapP10Lovelace = Nothing
            , snapP50Lovelace = Nothing
            , snapP90Lovelace = Nothing
            , snapTipSlot = rsTipSlot rs
            , snapLastTxId = lastTx
            }

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------

-- | Map the Cardano network magic to the ledger 'Network'.
networkFromMagic :: Word32 -> Network
networkFromMagic 764824073 = Mainnet
networkFromMagic _ = Testnet

-- | Pick the UTxO with the largest ADA value.
pickHighestValue ::
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra)
pickHighestValue =
    maximumBy
        ( compare
            `on` (\(_, o) -> o ^. coinTxOutL)
        )

{- | Convert a ledger 'TxId' + output index to the
indexer's 'Idx.TxIn'.
-}
ledgerToIndexerTxIn ::
    TxId -> Word16 -> Idx.TxIn
ledgerToIndexerTxIn (TxId h) ix =
    Idx.TxIn
        { Idx.txInId = hashToBytes (extractHash h)
        , Idx.txInIx = ix
        }

-- | Hex-encode a ledger 'TxId'.
txIdToHex :: TxId -> Text
txIdToHex (TxId h) =
    Text.decodeUtf8 (Base16.encode (hashToBytes (extractHash h)))

{- | Attach a key witness to a transaction body. Mirrors
the helper in
'Cardano.Node.Client.E2E.Setup.addKeyWitness' (kept
private here so the main library does not depend on the
@devnet@ test library).
-}
addKeyWitness ::
    SignKeyDSIGN Ed25519DSIGN ->
    ConwayTx ->
    ConwayTx
addKeyWitness sk tx =
    tx & witsTxL . addrTxWitsL %~ Set.union wits
  where
    wits =
        Set.singleton
            ( WitVKey
                (asWitness (VKey (deriveVerKeyDSIGN sk)))
                ( signedDSIGN
                    sk
                    ( extractHash
                        ( case txIdTx tx of
                            TxId h -> h
                        )
                    )
                )
            )

-- ----------------------------------------------------------------------
-- Chain-sync follower glue (mirrors UTxOIndexer.Daemon)
-- ----------------------------------------------------------------------

detectBootMode :: IndexerHandle -> IO BootMode
detectBootMode idx = do
    pairs <- getResumePoints idx
    pure $ case pairs of
        [] -> ColdBoot
        ps -> WarmBoot ps

toHeaderPoint :: (Idx.SlotNo, Idx.BlockHash) -> HeaderPoint
toHeaderPoint (Idx.SlotNo s, Idx.BlockHash bh) =
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

slotOfPoint :: HeaderPoint -> Idx.SlotNo
slotOfPoint p =
    case Network.pointSlot p of
        Network.Point.Origin -> Idx.SlotNo 0
        Network.Point.At s ->
            Idx.SlotNo (Network.unSlotNo s)

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
                let (slot, ops) =
                        extractBlock (fetchedBlock fetched)
                    bh = pointToBlockHash (fetchedPoint fetched)
                applyAtSlot idx slot bh ops
                _ <- pruneRollbacks idx (dcSecurityParamK cfg)
                updateReady cfg readyVar slot tip
                pure self
            , rollBackward = \point -> do
                let slot = case Network.pointSlot point of
                        Network.Point.Origin -> Idx.SlotNo 0
                        Network.Point.At s ->
                            Idx.SlotNo (Network.unSlotNo s)
                rollbackTo idx slot
                pure (Progress self)
            }

pointToBlockHash :: HeaderPoint -> Idx.BlockHash
pointToBlockHash p =
    case p of
        Network.Point Network.Point.Origin ->
            Idx.BlockHash mempty
        Network.Point
            (Network.Point.At (Network.Point.Block _ h)) ->
                Idx.BlockHash
                    (SBS.fromShort (getOneEraHash h))

updateReady ::
    DaemonConfig ->
    TVar ReadyState ->
    Idx.SlotNo ->
    Network.SlotNo ->
    IO ()
updateReady cfg readyVar (Idx.SlotNo processed) tipNet =
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
