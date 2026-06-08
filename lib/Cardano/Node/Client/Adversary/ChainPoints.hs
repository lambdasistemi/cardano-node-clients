{- |
Module      : Cardano.Node.Client.Adversary.ChainPoints
Description : Parse chain-points harvested by tracer-sidecar
License     : Apache-2.0

Reads a file emitted by the antithesis-side @tracer-sidecar@
container — one chain point per line in @\<hex\>@\<slot\>@ form, or
the literal @origin@. Used by the daemon's @chain_sync_flap@
endpoint to pick a randomised starting point for each adversarial
connection.

Lifted from
[`cardano-foundation/cardano-node-antithesis/components/adversary/src/Adversary.hs`](https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/components/adversary/src/Adversary.hs)
so the parsing logic lives next to the daemon that uses it.
-}
module Cardano.Node.Client.Adversary.ChainPoints (
    Point,
    originPoint,
    readChainPoint,
    parseChainPointSamples,
    generatePoints,
) where

import Cardano.Node.Client.Adversary.ChainSync.Codec (Point)
import Cardano.Node.Client.Adversary.ChainSync.Connection (HeaderHash)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Ouroboros.Consensus.HardFork.Combinator qualified as Consensus
import Ouroboros.Network.Block (SlotNo (..))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Point (WithOrigin (..))
import Ouroboros.Network.Point qualified as Point
import System.Random (StdGen, randomR)
import Text.Read (readMaybe)

-- | The chain's origin (genesis-before-first-block).
originPoint :: Point
originPoint = Network.Point Origin

-- | Parse one line. Format: @origin@ | @\<hex\>@\<slot\>@.
readChainPoint :: String -> Maybe Point
readChainPoint "origin" = Just originPoint
readChainPoint str = case split (== '@') str of
    [blockHashStr, slotNoStr] -> do
        (hash :: HeaderHash) <-
            Consensus.OneEraHash
                . SBS.toShort
                <$> either
                    (const Nothing)
                    Just
                    ( B16.decode $
                        T.encodeUtf8 $
                            T.pack blockHashStr
                    )
        slot <- SlotNo <$> readMaybe slotNoStr
        return $ Network.Point $ At $ Point.Block slot hash
    _ -> Nothing
  where
    split f = map T.unpack . T.split f . T.pack

{- | Parse a whole file (one chain point per line). Always prepends
'originPoint' to the resulting list so the adversary can also
start from genesis. Returns 'Nothing' if any individual line
fails to parse.
-}
parseChainPointSamples :: String -> Maybe (NonEmpty Point)
parseChainPointSamples =
    fmap (originPoint NE.:|)
        . mapM readChainPoint
        . lines

{- | Lazy infinite stream of points sampled uniformly from the
input.
-}
generatePoints :: StdGen -> NonEmpty Point -> NonEmpty Point
generatePoints g points = NE.unfoldr (fmap Just . randomElement points) g
  where
    randomElement :: NonEmpty a -> StdGen -> (a, StdGen)
    randomElement l g' =
        let (idx, g'') = randomR (0, length l - 1) g'
         in (l NE.!! idx, g'')
