{- |
Module      : Cardano.Node.Client.N2C.Codecs
Description : N2C protocol codec configuration
License     : Apache-2.0

Codec configuration shared between the
LocalStateQuery and LocalTxSubmission protocols.
Uses @CardanoNodeToClientVersion16@ and a
hard-coded 'EpochSlots' value of 42.
-}
module Cardano.Node.Client.N2C.Codecs (
    -- * Codec config
    ccfg,
    n2cVersion,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
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
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger (
    CodecConfig (ShelleyCodecConfig),
 )
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()

-- | Codec config with 'EpochSlots' 42.
ccfg :: Consensus.CardanoCodecConfig c
ccfg =
    CardanoCodecConfig
        (ByronCodecConfig $ EpochSlots 42)
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
            : Consensus.CardanoShelleyEras c
        )
n2cVersion = CardanoNodeToClientVersion16
