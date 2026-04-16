{- |
Module      : Cardano.Node.Client.N2C.Codecs
Description : N2C protocol codec configuration
License     : Apache-2.0

Codec configuration shared between the N2C mini-protocols:
LocalStateQuery, LocalTxSubmission, and ChainSync.
Uses @CardanoNodeToClientVersion16@ and a configurable
'EpochSlots' value (default 42 for devnet).
-}
module Cardano.Node.Client.N2C.Codecs (
    -- * Codec config
    ccfg,
    mkCcfg,
    n2cVersion,

    -- * ChainSync codec
    N2CChainSync,
    codecChainSyncN2C,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.Types (Block)
import Codec.Serialise (DeserialiseFailure, Serialise (..))
import Codec.Serialise.Decoding (Decoder)
import Codec.Serialise.Encoding (Encoding)
import Data.ByteString.Lazy qualified as LBS
import Data.Proxy (Proxy (..))
import Network.TypedProtocol.Codec (Codec)
import Ouroboros.Consensus.Block.Abstract (
    decodeRawHash,
    encodeRawHash,
 )
import Ouroboros.Consensus.Byron.Ledger (
    ByronBlock,
    CodecConfig (..),
 )
import Ouroboros.Consensus.Cardano.Block (
    CodecConfig (CardanoCodecConfig),
 )
import Ouroboros.Consensus.Cardano.Block qualified as Consensus
import Ouroboros.Consensus.Cardano.Node (
    pattern CardanoNodeToClientVersion16,
 )
import Ouroboros.Consensus.HardFork.Combinator.NetworkVersion (
    HardForkNodeToClientVersion,
 )
import Ouroboros.Consensus.Node.Serialisation (
    decodeNodeToClient,
    encodeNodeToClient,
 )
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger (
    CodecConfig (ShelleyCodecConfig),
 )
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block (
    decodeTip,
    encodeTip,
 )
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Protocol.ChainSync.Codec qualified as ChainSync
import Ouroboros.Network.Protocol.ChainSync.Type qualified as ChainSyncT

-- | Codec config with 'EpochSlots' 42 (devnet default).
ccfg :: Consensus.CardanoCodecConfig Consensus.StandardCrypto
ccfg = mkCcfg (EpochSlots 42)

-- | Build codec config with custom 'EpochSlots'.
mkCcfg ::
    EpochSlots ->
    Consensus.CardanoCodecConfig Consensus.StandardCrypto
mkCcfg es =
    CardanoCodecConfig
        (ByronCodecConfig es)
        ShelleyCodecConfig -- Shelley
        ShelleyCodecConfig -- Allegra
        ShelleyCodecConfig -- Mary
        ShelleyCodecConfig -- Alonzo
        ShelleyCodecConfig -- Babbage
        ShelleyCodecConfig -- Conway
        ShelleyCodecConfig -- Dijkstra

-- | N2C version for codec selection.
n2cVersion ::
    HardForkNodeToClientVersion
        ( ByronBlock
            : Consensus.CardanoShelleyEras
                Consensus.StandardCrypto
        )
n2cVersion = CardanoNodeToClientVersion16

-- | N2C ChainSync protocol type (block-level).
type N2CChainSync =
    ChainSyncT.ChainSync
        Block
        (Network.Point Block)
        (Network.Tip Block)

-- | N2C ChainSync codec — encodes/decodes full blocks.
codecChainSyncN2C ::
    EpochSlots ->
    Codec
        N2CChainSync
        DeserialiseFailure
        IO
        LBS.ByteString
codecChainSyncN2C es =
    ChainSync.codecChainSync
        (encBlockN2C es)
        (decBlockN2C es)
        encPointBlock
        decPointBlock
        encTip
        decTip

encBlockN2C :: EpochSlots -> Block -> Encoding
encBlockN2C es =
    encodeNodeToClient @Block (mkCcfg es) n2cVersion

decBlockN2C :: EpochSlots -> Decoder s Block
decBlockN2C es =
    decodeNodeToClient @Block (mkCcfg es) n2cVersion

encPointBlock :: Network.Point Block -> Encoding
encPointBlock = encode

decPointBlock :: Decoder s (Network.Point Block)
decPointBlock = decode

encTip :: Network.Tip Block -> Encoding
encTip = encodeTip (encodeRawHash (Proxy @Block))

decTip :: Decoder s (Network.Tip Block)
decTip = decodeTip (decodeRawHash (Proxy @Block))
