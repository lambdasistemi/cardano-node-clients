{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.UTxOIndexerSpec
Description : End-to-end test for the UTxO indexer daemon
License     : Apache-2.0

Boots a real @cardano-node@ devnet, runs 'runDaemon' in
the same process pointed at the node's Unix socket, then
exercises the daemon's NDJSON wire surface from a separate
client:

* @ready@ — poll until the daemon reports caught-up.
* Submit a self-transfer through 'Submitter' and use
  @await@ to block until the resulting @TxIn@ appears
  in a block — verifies the chain-sync → applyAtSlot →
  fireWaiters path end-to-end.
* @utxos_at@ — once the self-transfer has been observed,
  query the genesis address: the change output of the
  self-transfer must be visible. (Genesis funds live in
  the ledger seed, not in any block, so a chain-sync
  follower never sees them directly — exercising
  utxos_at first requires producing a block-level UTxO
  at the queried address.)

The daemon is run in-process via 'runDaemon' (rather than
as a separate binary) so the test exercises the same code
paths the executable does without paying for a process
spawn or for binary lookup.
-}
module Cardano.Node.Client.E2E.UTxOIndexerSpec (spec) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx (
    mkBasicTx,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Node.Client.Balance (balanceFeeLoop)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    devnetMagic,
    genesisAddr,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Probe (
    defaultProbeConfig,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Reconnect (
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Trace (
    nullN2CTracer,
 )
import Cardano.Node.Client.N2C.Types (LSQChannel, LTxSChannel)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    async,
    cancel,
    poll,
    withAsync,
 )
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    Socket,
    SocketType (Stream),
    close,
    connect,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
 )

spec :: Spec
spec =
    describe "UTxO indexer daemon (E2E)" $
        it
            "syncs devnet, serves ready / utxos_at / await over NDJSON"
            runE2E

-- | Single E2E that spans the whole daemon contract.
runE2E :: IO ()
runE2E = do
    gDir <- genesisDir
    withCardanoNode gDir $ \nodeSock _startMs ->
        withSystemTempDirectory "utxo-indexer-e2e" $ \tmp -> do
            let daemonSock = tmp </> "indexer.sock"
                cfg =
                    DaemonConfig
                        { dcRelaySocket = nodeSock
                        , dcListenSocket = daemonSock
                        , dcNetworkMagic = 42
                        , dcByronEpochSlots = 42
                        , dcReadyThresholdSlots = 60
                        , dcSecurityParamK = 2160
                        , dcDbPath = Nothing
                        , dcReconnectPolicy = defaultReconnectPolicy
                        , dcProbeConfig = defaultProbeConfig
                        }
            withAsync (runDaemon nullN2CTracer cfg) $ \daemonThread -> do
                waitForFile daemonSock 600
                poll daemonThread >>= \case
                    Just (Left e) ->
                        expectationFailure $
                            "daemon crashed during startup: "
                                <> show e
                    _ -> pure ()

                checkReady daemonSock 60
                txid <- driveSelfTransferAndAwait nodeSock daemonSock
                checkUtxosAtGenesisAfter daemonSock txid

-- * Sub-checks

-- | Poll @ready@ until @rsReady=true@ (or fail).
checkReady :: FilePath -> Int -> IO ()
checkReady _ 0 =
    expectationFailure "daemon never became ready"
checkReady sockPath n = do
    resp <- ndjsonRequest sockPath "{\"ready\":null}"
    case decodeReady resp of
        Just (True, _, _, _) -> pure ()
        _ -> threadDelay 1_000_000 >> checkReady sockPath (n - 1)

{- | Submit a self-transfer through 'Submitter' and use
@await@ to block until the resulting @TxIn@ shows up in
a block. Returns the txid bytes so the caller can keep
querying about the same tx.
-}
driveSelfTransferAndAwait ::
    FilePath -> FilePath -> IO ByteString
driveSelfTransferAndAwait nodeSock daemonSock =
    withN2CChannels nodeSock $ \lsq ltxs -> do
        let prov = mkN2CProvider lsq
            subm = mkN2CSubmitter ltxs
        pp <- queryProtocolParams prov
        seeds <- queryUTxOs prov genesisAddr
        case seeds of
            [] -> do
                expectationFailure "no genesis UTxOs"
                error "unreachable"
            (seed : _) -> do
                let tx = signSelfTransfer pp genesisAddr seed
                    TxId tidHash = txIdTx tx
                    tidBytes = hashToBytes (extractHash tidHash)
                    txInWire =
                        Text.encodeUtf8 (hex tidBytes) <> "#0"
                    req =
                        "{\"await\":\""
                            <> txInWire
                            <> "\",\"timeout_seconds\":60}"
                submitTx subm tx >>= \case
                    Submitted _ -> pure ()
                    Rejected r ->
                        expectationFailure $
                            "submitTx rejected: " <> show r
                resp <- ndjsonRequest daemonSock req
                case Aeson.decodeStrict' resp of
                    Just (Aeson.Object o)
                        | KM.lookup "timeout" o
                            == Just (Aeson.Bool True) ->
                            expectationFailure
                                "await timed out before the \
                                \submitted tx was observed"
                        | KM.member "slot" o -> pure ()
                    _ ->
                        expectationFailure $
                            "await response unexpected: "
                                <> show resp
                pure tidBytes

{- | Once a self-transfer has been observed in a block,
the indexer's view of @genesisAddr@ must contain its
change output (the only UTxO at @genesisAddr@ produced
inside a block — genesis-funded UTxOs live in the ledger
seed and are invisible to chain-sync). The change output
sits at index 0 of the just-submitted transaction.
-}
checkUtxosAtGenesisAfter :: FilePath -> ByteString -> IO ()
checkUtxosAtGenesisAfter sockPath tidBytes = do
    let addrHex = hex (serialiseAddr genesisAddr)
        req =
            "{\"utxos_at\":\""
                <> Text.encodeUtf8 addrHex
                <> "\"}"
        expected =
            hex tidBytes <> "#0"
    resp <- ndjsonRequest sockPath req
    case decodeUtxos resp of
        Just xs
            | any ((== expected) . fst) xs -> pure ()
        other ->
            expectationFailure $
                "utxos_at(genesis) missing self-transfer change: "
                    <> show other

-- * Self-transfer construction

{- | Balance and sign a single-output self-transfer back
to @addr@. Inputs == outputs + fee (strict conservation):
the change output absorbs everything left after the fee.
The same UTxO acts as spend input and collateral so the
transaction is self-contained.
-}
signSelfTransfer ::
    PParams ConwayEra ->
    Addr ->
    (TxIn, TxOut ConwayEra) ->
    ConwayTx
signSelfTransfer pp addr (seedIn, seedOut) =
    let Coin inputVal = seedOut ^. coinTxOutL
        mkOutputs (Coin fee) =
            let refund = inputVal - fee
             in if refund < 0
                    then Left "insufficient"
                    else
                        Right $
                            StrictSeq.singleton $
                                mkBasicTxOut
                                    addr
                                    (inject (Coin refund))
        template =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.singleton seedIn
                    & collateralInputsTxBodyL
                        .~ Set.singleton seedIn
                )
     in case balanceFeeLoop pp mkOutputs 1 [] template of
            Left err ->
                error $ "signSelfTransfer: " <> show err
            Right tx -> addKeyWitness genesisSignKey tx

-- * N2C client bracket against an already-running node

{- | Connect 'LSQChannel' + 'LTxSChannel' to a
@cardano-node@ running on @sock@. Mirrors the inner
half of 'Cardano.Node.Client.E2E.Setup.withDevnet' so
this test can run alongside an already-spawned node.
-}
withN2CChannels ::
    FilePath ->
    (LSQChannel -> LTxSChannel -> IO a) ->
    IO a
withN2CChannels sock action =
    bracket
        ( do
            lsq <- newLSQChannel 16
            ltxs <- newLTxSChannel 16
            t <- async (runNodeClient devnetMagic sock lsq ltxs)
            threadDelay 3_000_000
            poll t >>= \case
                Just (Left e) ->
                    error $ "N2C connect failed: " <> show e
                Just (Right (Left e)) ->
                    error $ "N2C connect error: " <> show e
                Just (Right (Right ())) ->
                    error "N2C closed unexpectedly"
                Nothing -> pure (lsq, ltxs, t)
        )
        (\(_, _, t) -> cancel t)
        (\(lsq, ltxs, _) -> action lsq ltxs)

-- * NDJSON client helpers

{- | One request, one response: open the daemon socket,
send @payload <> "\n"@, slurp the response until EOF.
-}
ndjsonRequest :: FilePath -> ByteString -> IO ByteString
ndjsonRequest sockPath payload =
    bracket connectClient close $ \s -> do
        Net.sendAll s (payload <> "\n")
        recvAll s
  where
    connectClient :: IO Socket
    connectClient = do
        s <- socket AF_UNIX Stream 0
        connect s (SockAddrUnix sockPath)
        pure s
    recvAll s = go BS.empty
      where
        go acc = do
            chunk <- Net.recv s 4096
            if BS.null chunk
                then pure acc
                else go (acc <> chunk)

{- | Wait up to @n@ deciseconds (100ms units) for a
filesystem path to appear. The daemon's listen socket
is bound asynchronously after 'runDaemon' starts.
-}
waitForFile :: FilePath -> Int -> IO ()
waitForFile path = go
  where
    go 0 =
        error $
            "waitForFile: nothing appeared at " <> path
    go n = do
        ok <- doesPathExist path
        if ok
            then pure ()
            else threadDelay 100_000 >> go (n - 1)

-- * Decoders

{- | @ready@ envelope: @(ready, tipSlot, processedSlot,
slotsBehind)@. The numeric fields are 'Maybe' because
the daemon emits @null@ when it has not yet seen a tip.
-}
decodeReady ::
    ByteString ->
    Maybe (Bool, Maybe Integer, Maybe Integer, Maybe Integer)
decodeReady bs = do
    Aeson.Object o <- Aeson.decodeStrict' bs
    rd <- KM.lookup "ready" o >>= asBool
    let tip = KM.lookup "tipSlot" o >>= asInt
        proc' = KM.lookup "processedSlot" o >>= asInt
        beh = KM.lookup "slotsBehind" o >>= asInt
    pure (rd, tip, proc', beh)
  where
    asBool (Aeson.Bool b) = Just b
    asBool _ = Nothing
    asInt :: Aeson.Value -> Maybe Integer
    asInt (Aeson.Number n) = Just (round n)
    asInt _ = Nothing

{- | Decode @{"utxos":[...]}@ into a list of
@(txin-text, txout-hex-text)@ pairs.
-}
decodeUtxos :: ByteString -> Maybe [(Text, Text)]
decodeUtxos bs = do
    Aeson.Object o <- Aeson.decodeStrict' bs
    Aeson.Array arr <- KM.lookup "utxos" o
    traverse decodeEntry (foldr (:) [] arr)
  where
    decodeEntry (Aeson.Object o) = do
        Aeson.String txin <- KM.lookup "txin" o
        Aeson.String txout <- KM.lookup "txout" o
        pure (txin, txout)
    decodeEntry _ = Nothing

-- * Misc

hex :: ByteString -> Text
hex = Text.decodeUtf8 . Base16.encode
