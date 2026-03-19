{- |
Module      : Cardano.Node.Client.N2C.ChainSync
Description : N2C ChainSync client and connection
License     : Apache-2.0

Provides an N2C ChainSync client that bridges the
generic 'Follower'/'Intersector' abstraction from
@chain-follower@ to the Ouroboros ChainSync protocol.

The client receives full blocks (not headers) and
wraps them in 'Fetched' records before passing to
the follower.
-}
module Cardano.Node.Client.N2C.ChainSync (
    -- * Connection
    runChainSyncN2C,

    -- * ChainSync client
    mkChainSyncN2C,
    N2CChainSyncApplication,

    -- * Block wrapper
    Fetched (..),
    HeaderPoint,
) where

import Cardano.Chain.Slotting (EpochSlots)
import Cardano.Node.Client.N2C.Codecs (
    codecChainSyncN2C,
 )
import Cardano.Node.Client.Types (Block)
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Exception (SomeException)
import Control.Tracer (Tracer, nullTracer, traceWith)
import Data.ByteString.Lazy (LazyByteString)
import Data.Function (fix)
import Data.Void (Void)
import Network.Mux qualified as Mx
import Ouroboros.Consensus.Cardano.Block qualified as Consensus
import Ouroboros.Consensus.Cardano.Node ()
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block (
    SlotNo,
    blockPoint,
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.IOManager (withIOManager)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Mux (
    MiniProtocol (..),
    MiniProtocolLimits (..),
    MiniProtocolNum (MiniProtocolNum),
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
import Ouroboros.Network.NodeToClient (
    connectTo,
    localSnocket,
    nullNetworkConnectTracers,
 )
import Ouroboros.Network.NodeToClient.Version (
    NodeToClientVersion (..),
    NodeToClientVersionData (..),
 )
import Ouroboros.Network.Point (
    WithOrigin (At, Origin),
 )
import Ouroboros.Network.Point qualified as Network.Point
import Ouroboros.Network.Protocol.ChainSync.Client (
    ChainSyncClient (..),
    ClientStIdle (..),
    ClientStIntersect (..),
    ClientStNext (..),
 )
import Ouroboros.Network.Protocol.ChainSync.Client qualified as ChainSync
import Ouroboros.Network.Protocol.Handshake.Version (
    simpleSingletonVersions,
 )
import Ouroboros.Network.Snocket (LocalAddress)

-- | Point type used by the follower (header-based).
type HeaderPoint =
    Network.Point
        (Consensus.CardanoHeader Consensus.StandardCrypto)

-- | N2C ChainSync client application type.
type N2CChainSyncApplication =
    ChainSyncClient
        Block
        (Network.Point Block)
        (Network.Tip Block)
        IO
        ()

-- | A fetched block with its point and chain tip slot.
data Fetched = Fetched
    { fetchedPoint :: HeaderPoint
    -- ^ Chain point of this block
    , fetchedBlock :: Block
    -- ^ The full block
    , fetchedTip :: SlotNo
    -- ^ Chain tip slot at fetch time
    }

{- | Connect to a Cardano node via Unix socket and run
an N2C ChainSync client. Blocks until the connection
closes or an error occurs.
-}
runChainSyncN2C ::
    -- | Byron epoch slots for codec
    EpochSlots ->
    -- | Network magic
    NetworkMagic ->
    -- | Path to node Unix socket
    FilePath ->
    -- | ChainSync client to run
    N2CChainSyncApplication ->
    IO (Either SomeException ())
runChainSyncN2C epochSlots magic socketPath app =
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
                $ mkN2CApp epochSlots app
            )
            socketPath

-- | Build the N2C application with ChainSync only.
mkN2CApp ::
    EpochSlots ->
    N2CChainSyncApplication ->
    OuroborosApplicationWithMinimalCtx
        Mx.InitiatorMode
        LocalAddress
        LazyByteString
        IO
        ()
        Void
mkN2CApp epochSlots chainSyncApp =
    OuroborosApplication
        { getOuroborosApplication =
            [ MiniProtocol
                { miniProtocolNum =
                    MiniProtocolNum 5
                , miniProtocolStart = StartOnDemand
                , miniProtocolLimits =
                    MiniProtocolLimits
                        { maximumIngressQueue = maxBound
                        }
                , miniProtocolRun =
                    InitiatorProtocolOnly $
                        mkMiniProtocolCbFromPeer $
                            const
                                ( nullTracer
                                , codecChainSyncN2C epochSlots
                                , ChainSync.chainSyncClientPeer
                                    chainSyncApp
                                )
                }
            ]
        }

{- | Create an N2C ChainSync client from a
'Follower'/'Intersector'. Receives full blocks,
wraps them in 'Fetched', and feeds them to the
follower.
-}
mkChainSyncN2C ::
    -- | Tracer for received blocks
    Tracer IO Block ->
    -- | Tracer for chain tip slot updates
    Tracer IO SlotNo ->
    -- | Callback for intersection/following
    Intersector HeaderPoint SlotNo Fetched ->
    -- | Starting points to find intersection
    [HeaderPoint] ->
    N2CChainSyncApplication
mkChainSyncN2C
    blockTracer
    tipTracer
    blockIntersector
    startingPoints =
        ChainSyncClient $
            pure $
                n2cIntersect
                    (coercePoints startingPoints)
                    blockIntersector
      where
        n2cIntersect ::
            [Network.Point Block] ->
            Intersector HeaderPoint SlotNo Fetched ->
            ClientStIdle
                Block
                (Network.Point Block)
                (Network.Tip Block)
                IO
                ()
        n2cIntersect points Intersector{intersectFound, intersectNotFound} =
            SendMsgFindIntersect points $
                ClientStIntersect
                    { recvMsgIntersectFound =
                        \point _ ->
                            ChainSyncClient $ do
                                nextFollower <-
                                    intersectFound
                                        (uncoercePoint point)
                                pure $ n2cFollow nextFollower
                    , recvMsgIntersectNotFound = \_ ->
                        ChainSyncClient $ do
                            (intersector', points') <-
                                intersectNotFound
                            pure $
                                n2cIntersect
                                    (coercePoints points')
                                    intersector'
                    }

        n2cFollow ::
            Follower HeaderPoint SlotNo Fetched ->
            ClientStIdle
                Block
                (Network.Point Block)
                (Network.Tip Block)
                IO
                ()
        n2cFollow initFollower = ($ initFollower) $
            fix $
                \go (Follower{rollForward, rollBackward}) ->
                    let
                        checkResult ::
                            IO
                                ( ProgressOrRewind
                                    HeaderPoint
                                    SlotNo
                                    Fetched
                                ) ->
                            N2CChainSyncApplication
                        checkResult getProgressOrRewind =
                            ChainSyncClient $ do
                                progressOrRewind <-
                                    getProgressOrRewind
                                case progressOrRewind of
                                    Progress follower' ->
                                        pure $ go follower'
                                    Rewind points intersector' ->
                                        pure $
                                            n2cIntersect
                                                (coercePoints points)
                                                intersector'
                                    Reset intersector' ->
                                        pure $
                                            n2cIntersect
                                                [ Network.Point
                                                    Origin
                                                ]
                                                intersector'
                     in
                        SendMsgRequestNext
                            (pure ())
                            ClientStNext
                                { recvMsgRollForward =
                                    \block tip ->
                                        checkResult $ do
                                            traceWith blockTracer block
                                            let tipSlot = tipToSlot tip
                                            traceWith tipTracer tipSlot
                                            Progress
                                                <$> rollForward
                                                    Fetched
                                                        { fetchedPoint =
                                                            uncoercePoint
                                                                (blockPoint block)
                                                        , fetchedBlock =
                                                            block
                                                        , fetchedTip =
                                                            tipSlot
                                                        }
                                                    tipSlot
                                , recvMsgRollBackward =
                                    \point _ ->
                                        checkResult $
                                            rollBackward
                                                (uncoercePoint point)
                                }

        tipToSlot :: Network.Tip Block -> SlotNo
        tipToSlot Network.TipGenesis = 0
        tipToSlot (Network.Tip slot _ _) = slot

-- | Coerce HeaderPoint to Block Point (same hash).
coercePoints :: [HeaderPoint] -> [Network.Point Block]
coercePoints = fmap coercePoint

coercePoint :: HeaderPoint -> Network.Point Block
coercePoint (Network.Point Origin) =
    Network.Point Origin
coercePoint (Network.Point (At (Network.Point.Block s h))) =
    Network.Point (At (Network.Point.Block s h))

-- | Coerce Block Point back to HeaderPoint.
uncoercePoint :: Network.Point Block -> HeaderPoint
uncoercePoint (Network.Point Origin) =
    Network.Point Origin
uncoercePoint (Network.Point (At (Network.Point.Block s h))) =
    Network.Point (At (Network.Point.Block s h))
