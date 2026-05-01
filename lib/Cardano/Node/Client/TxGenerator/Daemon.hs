{-# LANGUAGE LambdaCase #-}
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
    runDaemonWithTracer,
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
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Mainnet, Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TxOut, bodyTxL, extractHash)
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
import Cardano.Node.Client.N2C.Probe (ProbeConfig)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy,
    UpstreamStatus (..),
    runReconnectLoop,
 )
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Trace (
    N2CEvent,
    defaultStderrTracer,
 )
import Cardano.Node.Client.N2C.Types (ConnectionLost (..))
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxGenerator.Build (
    refillTx,
    transactTx,
 )
import Cardano.Node.Client.TxGenerator.Fanout (
    Destination (..),
    pickDestinations,
 )
import Cardano.Node.Client.TxGenerator.Persist (
    loadOrCreateSeed,
    nextHDIndexPath,
    readNextHDIndex,
    writeNextHDIndex,
 )
import Cardano.Node.Client.TxGenerator.Population (
    deriveAddr,
    deriveSignKey,
    enterpriseAddrFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.TxGenerator.Selection (
    pickSourceIndex,
    verifyInputsUnspent,
 )
import Cardano.Node.Client.TxGenerator.Server (
    ServerHooks (..),
    runServer,
 )
import Cardano.Node.Client.TxGenerator.Snapshot (
    collectPopulationValues,
    percentiles,
 )
import Cardano.Node.Client.TxGenerator.Types (
    FailureReason (..),
    ReadyResponse (..),
    RefillRequest,
    RefillResponse (..),
    SnapshotResponse (..),
    TransactRequest (..),
    TransactResponse (..),
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
    modifyTVar',
    newTVarIO,
    readTVarIO,
    writeTVar,
 )
import Control.Exception qualified as E
import Control.Monad (void)
import Control.Tracer (Tracer, nullTracer)
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
import Data.Void (Void)
import Data.Word (Word16, Word32, Word64)
import Lens.Micro ((%~), (&), (^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (
    OneEraHash (..),
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.Directory (createDirectoryIfMissing)
import System.Random (mkStdGen)
import System.Random qualified

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
    , dcReconnectPolicy :: !ReconnectPolicy
    -- ^ Policy used by the N2C reconnect supervisor
    -- wrapping the relay connection. Defaults via
    -- 'defaultReconnectPolicy'.
    , dcProbeConfig :: !ProbeConfig
    -- ^ Pre-attempt probe used by the supervisor to wait
    -- for the relay's ChainDB to finish loading. Defaults
    -- via 'defaultProbeConfig' — chain-replay-tolerant
    -- (unbounded total wait, replay-aware retries).
    }
    deriving stock (Show)

{- | Mirrors the indexer's per-run readiness state. The
'rsUpstream' field surfaces the reconnect supervisor's
view of the bearer; 'readyResponseFrom' enforces the
invariant @UpstreamDisconnected => ready=false@ on the
wire.

'rsIndexFresh' is orthogonal to 'rsReady' (which gates on
tip-distance) and 'rsUpstream' (which gates on bearer
state). It captures whether the indexer has applied at
least one block since the most recent reconnect: false on
cold start and on every transition into 'UpstreamConnected';
true after the first 'rollForward' completes (issue #109).
-}
data ReadyState = ReadyState
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe Word64)
    , rsProcessedSlot :: !(Maybe Word64)
    , rsUpstream :: !UpstreamStatus
    , rsIndexFresh :: !Bool
    }
    deriving stock (Show)

initialReady :: ReadyState
initialReady =
    ReadyState
        { rsReady = False
        , rsTipSlot = Nothing
        , rsProcessedSlot = Nothing
        , rsUpstream = UpstreamConnected
        , rsIndexFresh = False
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

The relay connection is wrapped in
'Cardano.Node.Client.N2C.Reconnect.runReconnectLoop'.
When the upstream relay closes the bearer (network
partition, container restart, or the
'Network.Socket.sendBuf: resource vanished (Broken pipe)'
/ @BlockedIndefinitely@ pair we observed under
Antithesis fault injection on
cardano-foundation/cardano-node-antithesis @ ed6666d) the
supervisor catches the exception, flips
'rsUpstream' to 'UpstreamDisconnected', re-probes the
relay, and reopens the connection. The control surface
stays bound throughout; @ready@ responses advertise the
upstream gap; in-flight LSQ/LTxS requests fail fast and
callers retry on the next composer tick.
-}
runDaemon :: DaemonConfig -> IO ()
runDaemon = runDaemonWithTracer defaultStderrTracer

{- | Variant of 'runDaemon' that takes an explicit
'N2CEvent' tracer. Wired this way so tests can capture
supervisor events; the binary uses 'runDaemon' which
defaults to the stderr renderer.
-}
runDaemonWithTracer :: Tracer IO N2CEvent -> DaemonConfig -> IO ()
runDaemonWithTracer tracer cfg = do
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
            -- One full N2C session: chain-sync + LSQ +
            -- LTxS over a single mux bearer. Wrapped in
            -- 'try' so synchronous exceptions surface to
            -- the supervisor instead of escaping it.
            nodeSession =
                E.try $
                    void $
                        runNodeClientFull
                            (NetworkMagic (dcNetworkMagic cfg))
                            (EpochSlots (dcByronEpochSlots cfg))
                            (dcRelaySocket cfg)
                            chainSyncApp
                            lsqCh
                            ltxsCh
            -- Status sink: every supervisor transition
            -- goes through this. On UpstreamDisconnected
            -- we also force rsReady=False at the
            -- producer (the encoder enforces the same
            -- invariant on the wire — defense in depth).
            -- On UpstreamConnected we clear rsIndexFresh
            -- so the arms refuse to read a stale UTxO
            -- view until the chain-sync follower has
            -- applied at least one post-reconnect block
            -- (issue #109). rsIndexFresh flips back to
            -- true inside 'updateReady'.
            setUpstreamStatus newStatus =
                atomically $ modifyTVar' readyVar $ \rs ->
                    case newStatus of
                        UpstreamConnected ->
                            rs
                                { rsUpstream = UpstreamConnected
                                , rsIndexFresh = False
                                }
                        UpstreamDisconnected _ ->
                            rs
                                { rsUpstream = newStatus
                                , rsReady = False
                                }
            getProcessedSlot =
                fmap Idx.SlotNo . rsProcessedSlot
                    <$> readTVarIO readyVar
            supervisedNodeAction :: IO Void
            supervisedNodeAction =
                runReconnectLoop
                    tracer
                    (dcReconnectPolicy cfg)
                    (dcProbeConfig cfg)
                    (NetworkMagic (dcNetworkMagic cfg))
                    (dcRelaySocket cfg)
                    setUpstreamStatus
                    getProcessedSlot
                    nodeSession
        withAsync (void supervisedNodeAction) $ \_nodeT -> do
            -- Brief settle for the mux handshake. The
            -- probe in 'runReconnectLoop' has already
            -- confirmed the relay's LSQ answers, so this
            -- is just a courtesy gap before the first
            -- queryProtocolParams.
            threadDelay 3_000_000
            let provider = mkN2CProvider lsqCh
                submitter = mkN2CSubmitter ltxsCh
            -- Boot-time LSQ probes can race the supervisor
            -- if the bearer dies during chain replay; loop
            -- with a short backoff so the daemon process
            -- survives early disconnects too. The
            -- supervisor is already retrying the bearer
            -- itself; this just keeps the boot waiting
            -- until LSQ is reachable.
            let bootRetry :: forall a. IO a -> IO a
                bootRetry act =
                    E.try @ConnectionLost act >>= \case
                        Right v -> pure v
                        Left ConnectionLost -> do
                            threadDelay 500_000
                            bootRetry act
            pp <- bootRetry (queryProtocolParams provider)
            -- Probe the faucet once at startup so the
            -- @ready@ probe can flip @faucetUtxosKnown@
            -- without waiting for the first @refill@
            -- trigger. Subsequent refills update this flag
            -- per their LSQ response.
            initialFaucetUtxos <-
                bootRetry (queryUTxOs provider faucetAddr)
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
                        idx
                        net
                        masterSeed
                -- Both arms can raise 'ConnectionLost' when
                -- a request is in flight at the moment the
                -- N2C bearer dies. The reconnect supervisor
                -- reopens the bearer; the arm just needs to
                -- surface a not-applicable response so the
                -- composer retries on the next tick instead
                -- of taking down the daemon process.
                --
                -- The freshness gate ('rsIndexFresh') runs
                -- before the arm body: between the
                -- supervisor flipping rsUpstream to
                -- 'UpstreamConnected' and the chain-sync
                -- follower applying its first post-reconnect
                -- block, the indexer's UTxO view is stale
                -- (#109). Reading it would lead to a refill
                -- submitting against already-spent inputs
                -- ('ConwayMempoolFailure "All inputs are
                -- spent"') or a transact returning
                -- 'no-pickable-source'. We short-circuit
                -- with 'IndexNotReady' instead so the
                -- composer retries on the next tick.
                indexFresh =
                    rsIndexFresh <$> readTVarIO readyVar
                doRefill req =
                    indexFresh >>= \case
                        False ->
                            pure (RefillFail IndexNotReady)
                        True ->
                            E.handle
                                ( \ConnectionLost ->
                                    pure
                                        ( RefillFail
                                            IndexNotReady
                                        )
                                )
                                ( runRefillArm
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
                                    req
                                )
                doTransact req =
                    indexFresh >>= \case
                        False ->
                            pure (TransactFail IndexNotReady)
                        True ->
                            E.handle
                                ( \ConnectionLost ->
                                    pure
                                        ( TransactFail
                                            IndexNotReady
                                        )
                                )
                                ( runTransactArm
                                    cfg
                                    pp
                                    idx
                                    provider
                                    submitter
                                    net
                                    masterSeed
                                    nextIdxMVar
                                    lastTxIdVar
                                    req
                                )
                hooks =
                    ServerHooks
                        { hooksReady = getReady
                        , hooksSnapshot = getSnapshot
                        , hooksTransact = doTransact
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
                                provider
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
    Provider IO ->
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
    provider
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
                    inputs = signed ^. bodyTxL . inputsTxBodyL
                inputsOk <- verifyInputsUnspent provider inputs
                if not inputsOk
                    then
                        pure
                            ( currentIdx
                            , RefillFail IndexNotReady
                            )
                    else do
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
-- Transact arm (User Story 1 / T011)
-- ----------------------------------------------------------------------

{- | Defensive minimum-UTxO floor used for fanout value
sampling. Conway's actual minimum is computed from
@ppCoinsPerUTxOByte * size@; 1.5 ADA is comfortably above
that for an enterprise-address output. The TxBuild
balancer surfaces 'MinUtxoViolation' if a destination
slips below the era's floor.
-}
defaultMinUtxo :: Coin
defaultMinUtxo = Coin 1_500_000

{- | Defensive fee reserve subtracted from the source
UTxO value before the fanout. The TxBuild balancer
computes the actual fee; this reserve only exists to
keep @available@ below "value left for distribution"
so the change output stays above 'defaultMinUtxo'.
-}
defaultFeeReserve :: Coin
defaultFeeReserve = Coin 5_000_000

{- | Run one transact: take the next-HD-index lock,
sample a viable source HD index from the request seed
via 'pickSourceIndex', sample K destinations + values
via 'pickDestinations', materialize destination
addresses, build the tx, sign with the source's key,
submit, await the change UTxO via the indexer, persist
the bumped next-HD-index, and return the wire response.

Any pre-submit failure (no-pickable-source, build
failure, submit-rejected) leaves the next-HD-index
unchanged.
-}
runTransactArm ::
    DaemonConfig ->
    PParams ConwayEra ->
    IndexerHandle ->
    Provider IO ->
    Submitter IO ->
    Network ->
    ByteString ->
    MVar Word64 ->
    TVar (Maybe Text) ->
    TransactRequest ->
    IO TransactResponse
runTransactArm
    cfg
    pp
    idx
    provider
    submitter
    net
    masterSeed
    nextIdxMVar
    lastTxIdVar
    req =
        modifyMVar nextIdxMVar $ \currentIdx ->
            if currentIdx == 0
                then
                    pure
                        ( currentIdx
                        , TransactFail NoPickableSource
                        )
                else do
                    let seed = txReqSeed req
                        kWord = txReqFanout req
                        kInt = fromIntegral kWord :: Word64
                        gen0 = mkStdGen (fromIntegral seed)
                        floorLovelace =
                            kInt
                                * fromIntegral
                                    (unCoin defaultMinUtxo)
                                + fromIntegral
                                    (unCoin defaultFeeReserve)
                                + fromIntegral
                                    (unCoin defaultMinUtxo)
                        viable srcIdx = do
                            let addr =
                                    deriveAddr net masterSeed srcIdx
                            utxos <- queryUTxOs provider addr
                            pure $ case utxos of
                                [] -> False
                                xs ->
                                    let bestVal =
                                            maximum
                                                ( fmap
                                                    ( \(_, o) ->
                                                        unCoin
                                                            (o ^. coinTxOutL)
                                                    )
                                                    xs
                                                )
                                     in bestVal
                                            >= toInteger floorLovelace
                    pickResult <-
                        pickSourceIndex
                            viable
                            currentIdx
                            (defaultMaxPickRetries cfg)
                            gen0
                    case pickResult of
                        Nothing ->
                            pure
                                ( currentIdx
                                , TransactFail NoPickableSource
                                )
                        Just (srcIdx, gen1) ->
                            transactWithSource
                                cfg
                                pp
                                idx
                                provider
                                submitter
                                net
                                masterSeed
                                lastTxIdVar
                                req
                                currentIdx
                                srcIdx
                                gen1

defaultMaxPickRetries :: DaemonConfig -> Word32
defaultMaxPickRetries _ = 16

transactWithSource ::
    DaemonConfig ->
    PParams ConwayEra ->
    IndexerHandle ->
    Provider IO ->
    Submitter IO ->
    Network ->
    ByteString ->
    TVar (Maybe Text) ->
    TransactRequest ->
    Word64 ->
    Word64 ->
    System.Random.StdGen ->
    IO (Word64, TransactResponse)
transactWithSource
    cfg
    pp
    idx
    provider
    submitter
    net
    masterSeed
    lastTxIdVar
    req
    currentIdx
    srcIdx
    gen1 = do
        let srcSKey = deriveSignKey masterSeed srcIdx
            srcAddr = deriveAddr net masterSeed srcIdx
        utxos <- queryUTxOs provider srcAddr
        case utxos of
            [] ->
                pure
                    ( currentIdx
                    , TransactFail NoPickableSource
                    )
            xs -> do
                let (srcIn, srcOut) = pickHighestValue xs
                    srcVal = srcOut ^. coinTxOutL
                    available =
                        Coin
                            ( unCoin srcVal
                                - unCoin defaultFeeReserve
                                - unCoin defaultMinUtxo
                            )
                    (dests, newNextIdx, _gen2) =
                        pickDestinations
                            currentIdx
                            (txReqFanout req)
                            (txReqProbFresh req)
                            available
                            defaultMinUtxo
                            gen1
                    destAddrs =
                        fmap
                            ( \d ->
                                ( deriveAddr
                                    net
                                    masterSeed
                                    (destIndex d)
                                , destValue d
                                )
                            )
                            dests
                buildResult <-
                    transactTx
                        pp
                        (srcIn, srcOut)
                        destAddrs
                        srcAddr
                case buildResult of
                    Left err ->
                        pure
                            ( currentIdx
                            , TransactFail (SubmitRejected err)
                            )
                    Right tx -> do
                        let signed = addKeyWitness srcSKey tx
                            inputs =
                                signed ^. bodyTxL . inputsTxBodyL
                        inputsOk <-
                            verifyInputsUnspent provider inputs
                        if not inputsOk
                            then
                                pure
                                    ( currentIdx
                                    , TransactFail IndexNotReady
                                    )
                            else do
                                result <- submitTx submitter signed
                                case result of
                                    Rejected reason -> do
                                        let reasonText =
                                                Text.decodeUtf8With
                                                    (\_ _ -> Just '\xFFFD')
                                                    reason
                                        pure
                                            ( currentIdx
                                            , TransactFail
                                                (SubmitRejected reasonText)
                                            )
                                    Submitted txId -> do
                                        -- The change output is at
                                        -- index K (after the K
                                        -- explicit destinations).
                                        let changeIxn =
                                                ledgerToIndexerTxIn
                                                    txId
                                                    ( fromIntegral
                                                        ( txReqFanout req
                                                        ) ::
                                                        Word16
                                                    )
                                            timeoutS =
                                                Just
                                                    (dcAwaitTimeoutSeconds cfg)
                                        obs <-
                                            awaitTxIn
                                                idx
                                                changeIxn
                                                timeoutS
                                        let awaited =
                                                isJust
                                                    ( obs ::
                                                        Maybe AwaitObservation
                                                    )
                                            txHex = txIdToHex txId
                                            freshCount =
                                                fromIntegral
                                                    ( length
                                                        ( filter
                                                            destFresh
                                                            dests
                                                        )
                                                    )
                                        writeNextHDIndex
                                            ( nextHDIndexPath
                                                (dcStateDir cfg)
                                            )
                                            newNextIdx
                                        atomically
                                            ( writeTVar
                                                lastTxIdVar
                                                (Just txHex)
                                            )
                                        pure
                                            ( newNextIdx
                                            , TransactOk
                                                { txOkTxId = txHex
                                                , txOkSrc = srcIdx
                                                , txOkDsts =
                                                    fmap destIndex dests
                                                , txOkValuesLovelace =
                                                    fmap
                                                        (unCoin . destValue)
                                                        dests
                                                , txOkFreshCount =
                                                    freshCount
                                                , txOkAwaited = awaited
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
    -- Defense in depth: when the supervisor reports
    -- 'UpstreamDisconnected' the client must treat the
    -- daemon as not-ready even if the producer's TVar
    -- still has 'rsReady=True' from before the bearer
    -- closed. The encoder-side enforcement in
    -- 'TxGenerator.Types.ReadyResponse'\''s 'ToJSON' makes
    -- this an invariant on the wire.
    let ready = case rsUpstream rs of
            UpstreamConnected -> rsReady rs && fk
            UpstreamDisconnected{} -> False
        indexReady = case rsUpstream rs of
            UpstreamConnected -> rsReady rs
            UpstreamDisconnected{} -> False
    pure
        ReadyResponse
            { readyReady = ready
            , readyIndexReady = indexReady
            , readyFaucetUtxosKnown = fk
            , readyUpstream = rsUpstream rs
            }

snapshotResponseFrom ::
    FilePath ->
    TVar ReadyState ->
    TVar (Maybe Text) ->
    IndexerHandle ->
    Network ->
    ByteString ->
    IO SnapshotResponse
snapshotResponseFrom
    indexPath
    readyVar
    lastTxIdVar
    idx
    net
    masterSeed = do
        nextIdx <- readNextHDIndex indexPath
        rs <- readTVarIO readyVar
        lastTx <- readTVarIO lastTxIdVar
        values <- collectPopulationValues idx net masterSeed nextIdx
        let (p10, p50, p90) = case percentiles values of
                Nothing -> (Nothing, Nothing, Nothing)
                Just (Coin a, Coin b, Coin c) ->
                    (Just a, Just b, Just c)
        pure
            SnapshotResponse
                { snapPopulationSize = nextIdx
                , snapP10Lovelace = p10
                , snapP50Lovelace = p50
                , snapP90Lovelace = p90
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
updateReady cfg readyVar (Idx.SlotNo processed) tipNet = do
    let tip = Network.unSlotNo tipNet
        behind =
            if tip > processed
                then tip - processed
                else 0
        ready = behind <= dcReadyThresholdSlots cfg
    -- Preserve the supervisor-managed 'rsUpstream'. The
    -- chain-sync follower owns rsReady/rsTipSlot/
    -- rsProcessedSlot/rsIndexFresh; the supervisor owns
    -- rsUpstream. rsIndexFresh flips true here on every
    -- applied 'rollForward' — which proves chain-sync has
    -- resumed past the most recent reconnect anchor and
    -- the indexer's UTxO view is no longer stale (#109).
    atomically $ modifyTVar' readyVar $ \rs ->
        rs
            { rsReady = ready
            , rsTipSlot = Just tip
            , rsProcessedSlot = Just processed
            , rsIndexFresh = True
            }
