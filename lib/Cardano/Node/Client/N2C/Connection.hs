{- |
Module      : Cardano.Node.Client.N2C.Connection
Description : N2C connection with LSQ + LTxS
License     : Apache-2.0

Establishes a node-to-client (N2C) connection via
Unix socket, multiplexing two mini-protocols:
LocalStateQuery (num 7) for UTxO and protocol
parameter queries, and LocalTxSubmission (num 6)
for signed transaction submission. The connection
blocks until closed — run in a background thread.
-}
module Cardano.Node.Client.N2C.Connection (
    -- * Connection
    runNodeClient,

    -- * Channel creation
    newLSQChannel,
    newLTxSChannel,
) where

import Cardano.Network.NodeToClient (
    NodeToClientVersion (..),
    NodeToClientVersionData (..),
    connectTo,
    localSnocket,
    nullNetworkConnectTracers,
 )
import Cardano.Network.Protocol.LocalStateQuery.Codec (
    Some (..),
    codecLocalStateQuery,
 )
import Cardano.Node.Client.N2C.Codecs (
    ccfg,
    n2cVersion,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (
    mkLocalStateQueryClient,
 )
import Cardano.Node.Client.N2C.LocalTxSubmission (
    mkLocalTxSubmissionClient,
 )
import Cardano.Node.Client.N2C.Types (
    LSQChannel (..),
    LTxSChannel (..),
 )
import Cardano.Node.Client.Types (Block)
import Control.Concurrent.STM (newTBQueueIO)
import Control.Exception (SomeException)
import Control.Tracer (nullTracer)
import Data.ByteString.Lazy (LazyByteString)
import Data.Proxy (Proxy (..))
import Data.Void (Void)
import Network.Mux qualified as Mx
import Ouroboros.Consensus.Block.Abstract (
    decodeRawHash,
    encodeRawHash,
 )
import Ouroboros.Consensus.Block.NestedContent (
    SomeSecond (..),
 )
import Ouroboros.Consensus.Ledger.Query (
    nodeToClientVersionToQueryVersion,
    queryDecodeNodeToClient,
    queryEncodeNodeToClient,
 )
import Ouroboros.Consensus.Node.Serialisation (
    decodeNodeToClient,
    decodeResult,
    encodeNodeToClient,
    encodeResult,
 )
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block (
    decodePoint,
    encodePoint,
 )
import Ouroboros.Network.Driver.Stateful qualified as Stateful
import Ouroboros.Network.IOManager (withIOManager)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Mux (
    MiniProtocol (..),
    MiniProtocolCb (..),
    MiniProtocolLimits (..),
    MiniProtocolNum (..),
    OuroborosApplication (..),
    OuroborosApplicationWithMinimalCtx,
    RunMiniProtocol (
        InitiatorProtocolOnly
    ),
    StartOnDemandOrEagerly (
        StartOnDemand
    ),
    mkMiniProtocolCbFromPeer,
 )
import Ouroboros.Network.Protocol.Handshake.Version (
    simpleSingletonVersions,
 )
import Ouroboros.Network.Protocol.LocalStateQuery.Client qualified as LSQ
import Ouroboros.Network.Protocol.LocalStateQuery.Type (
    State (..),
 )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client qualified as LTxS
import Ouroboros.Network.Protocol.LocalTxSubmission.Codec qualified as LTxSCodec
import Ouroboros.Network.Snocket (LocalAddress)

-- | Maximum ingress queue for mini-protocols.
maxLimits :: MiniProtocolLimits
maxLimits =
    MiniProtocolLimits
        { maximumIngressQueue = maxBound
        }

{- | Connect to a Cardano node via Unix socket and
run LocalStateQuery + LocalTxSubmission clients.

This blocks until the connection is closed or an
error occurs. Run in a background thread with
'Control.Concurrent.Async.async'.
-}
runNodeClient ::
    -- | Network magic (e.g. mainnet = 764824073)
    NetworkMagic ->
    -- | Path to the node Unix socket
    FilePath ->
    -- | Channel for LocalStateQuery requests
    LSQChannel ->
    -- | Channel for LocalTxSubmission requests
    LTxSChannel ->
    IO (Either SomeException ())
runNodeClient magic socketPath lsqCh ltxsCh =
    withIOManager $ \ioManager ->
        connectTo
            (localSnocket ioManager)
            nullNetworkConnectTracers
            ( simpleSingletonVersions
                NodeToClientV_20
                NodeToClientVersionData
                    { networkMagic = magic
                    , query = False
                    }
                $ const
                $ mkN2CApp lsqCh ltxsCh
            )
            socketPath

{- | Build the N2C application with
LocalStateQuery and LocalTxSubmission.
-}
mkN2CApp ::
    LSQChannel ->
    LTxSChannel ->
    OuroborosApplicationWithMinimalCtx
        Mx.InitiatorMode
        LocalAddress
        LazyByteString
        IO
        ()
        Void
mkN2CApp lsqCh ltxsCh =
    OuroborosApplication
        { getOuroborosApplication =
            [ -- LocalTxSubmission (num 6)
              MiniProtocol
                { miniProtocolNum =
                    MiniProtocolNum 6
                , miniProtocolStart = StartOnDemand
                , miniProtocolLimits = maxLimits
                , miniProtocolRun =
                    InitiatorProtocolOnly $
                        mkMiniProtocolCbFromPeer $
                            const
                                ( nullTracer
                                , ltxsCodec
                                , LTxS.localTxSubmissionClientPeer $
                                    mkLocalTxSubmissionClient
                                        ltxsCh
                                )
                }
            , -- LocalStateQuery (num 7)
              MiniProtocol
                { miniProtocolNum =
                    MiniProtocolNum 7
                , miniProtocolStart = StartOnDemand
                , miniProtocolLimits = maxLimits
                , miniProtocolRun =
                    InitiatorProtocolOnly $
                        MiniProtocolCb $
                            \_ctx channel ->
                                Stateful.runPeer
                                    nullTracer
                                    lsqCodec
                                    channel
                                    StateIdle
                                    $ LSQ.localStateQueryClientPeer
                                    $ mkLocalStateQueryClient
                                        lsqCh
                }
            ]
        }
  where
    ltxsCodec =
        LTxSCodec.codecLocalTxSubmission
            (encodeNodeToClient @Block ccfg n2cVersion)
            (decodeNodeToClient @Block ccfg n2cVersion)
            (encodeNodeToClient @Block ccfg n2cVersion)
            (decodeNodeToClient @Block ccfg n2cVersion)
    lsqCodec =
        codecLocalStateQuery
            NodeToClientV_20
            (encodePoint (encodeRawHash (Proxy @Block)))
            (decodePoint (decodeRawHash (Proxy @Block)))
            ( queryEncodeNodeToClient
                ccfg
                qv
                n2cVersion
                . SomeSecond
            )
            ( (\(SomeSecond q) -> Some q)
                <$> queryDecodeNodeToClient
                    ccfg
                    qv
                    n2cVersion
            )
            (encodeResult ccfg n2cVersion)
            (decodeResult ccfg n2cVersion)
    qv =
        nodeToClientVersionToQueryVersion
            NodeToClientV_20

{- | Create a new 'LSQChannel' with the given queue
capacity.
-}
newLSQChannel ::
    -- | Maximum number of queued queries
    Int ->
    IO LSQChannel
newLSQChannel capacity =
    LSQChannel
        <$> newTBQueueIO (fromIntegral capacity)

{- | Create a new 'LTxSChannel' with the given queue
capacity.
-}
newLTxSChannel ::
    -- | Maximum number of queued submissions
    Int ->
    IO LTxSChannel
newLTxSChannel capacity =
    LTxSChannel
        <$> newTBQueueIO (fromIntegral capacity)
