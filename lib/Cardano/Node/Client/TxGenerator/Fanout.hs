{- |
Module      : Cardano.Node.Client.TxGenerator.Fanout
Description : K-output fan-out destination selection
License     : Apache-2.0

Pure logic for the @transact@ arm's destination + value
sampling (per
@specs/034-cardano-tx-generator/data-model.md§Destinations@):

* For each of K output slots, decide whether the
  destination is a fresh population address (Bernoulli on
  @prob_fresh@) or a sample from the existing population
  drawn uniformly from @[0, nextHDIndex)@.
* Sample the per-output value uniformly from
  @[minUTxO, available `div` K]@.

The function is pure in 'IO' — it operates on the
caller's 'StdGen' and returns the advanced state so the
same per-request seed produces a byte-identical output
sequence (FR-002 / SC-002).

Address derivation is not done here; the daemon turns
@(index, fresh)@ tuples into real 'Addr's via
'Cardano.Node.Client.TxGenerator.Population.deriveAddr'.
-}
module Cardano.Node.Client.TxGenerator.Fanout (
    -- * Fan-out
    pickDestinations,
    Destination (..),
) where

import Cardano.Ledger.Coin (Coin (..))
import Data.Word (Word64, Word8)
import System.Random (Random (random), StdGen, randomR)

{- | One output slot of a transact transaction. The
@destFresh@ flag tells the daemon whether to mint a new
HD address at @destIndex@ (then bump @nextHDIndex@) or
to reuse an existing population address.
-}
data Destination = Destination
    { destIndex :: !Word64
    , destFresh :: !Bool
    , destValue :: !Coin
    }
    deriving stock (Eq, Show)

{- | Pick K destinations and per-output values, advancing
the 'StdGen' once per coin flip and once per value draw
(2 K draws total).

Returns the list of K 'Destination's, the new
@nextHDIndex@ (= old + count of fresh destinations), and
the advanced 'StdGen'.

If @minUTxO * K > available@ — i.e. the source UTxO did
not pass the viability floor — the per-output range is
clamped at @minUTxO@ (every output is exactly the
minimum). The caller (Selection.pickSource) is expected
to enforce viability up-front; this fallback exists only
to keep the function total.

When the existing population is empty (@nextHDIndex0 ==
0@) every coin flip is forced to "fresh" regardless of
@prob_fresh@; otherwise we'd have to sample from an empty
range. That coincides with the cold-start case after a
single refill: only one address exists, so the
"reuse-existing" branch can only pick that one.
-}
pickDestinations ::
    -- | population size at the start of the transact
    --     (== current next-HD-index).
    Word64 ->
    -- | K, the number of output slots.
    Word8 ->
    -- | probability that a destination is freshly
    --     derived (Bernoulli, in [0, 1]).
    Double ->
    -- | available value to distribute across K outputs.
    --     The change output absorbs whatever is left over
    --     after the per-output samples and the fee.
    Coin ->
    -- | protocol minimum UTxO.
    Coin ->
    -- | RNG state from the request seed.
    StdGen ->
    ([Destination], Word64, StdGen)
pickDestinations nextIdx0 k probFresh (Coin available) (Coin minUtxo) gen0 =
    let kInt = fromIntegral k :: Word64
        upperPerOutput =
            let perK = available `div` toInteger kInt
             in max minUtxo perK
        (rev, finalIdx, finalGen) =
            foldl
                ( \(acc, idx, g) _ ->
                    let (dest, idx', g'') =
                            stepOne
                                idx
                                nextIdx0
                                probFresh
                                minUtxo
                                upperPerOutput
                                g
                     in (dest : acc, idx', g'')
                )
                ([], nextIdx0, gen0)
                [1 .. kInt]
     in (reverse rev, finalIdx, finalGen)

{- | One output slot's worth of sampling: coin-flip
fresh-vs-existing, sample destination index, sample
value.
-}
stepOne ::
    -- | running next-HD-index (carries fresh increments)
    Word64 ->
    -- | population at the START of the transact (so
    --     existing-pick samples from a stable range)
    Word64 ->
    -- | prob_fresh
    Double ->
    -- | minUTxO (Integer lovelace)
    Integer ->
    -- | upper bound per output (Integer lovelace)
    Integer ->
    StdGen ->
    (Destination, Word64, StdGen)
stepOne idx pop probFresh minUtxo upper gen =
    let (b, gen') = random gen :: (Double, StdGen)
        forceFresh = pop == 0
        isFresh = forceFresh || b < probFresh
        (chosenIdx, gen'', idx') =
            if isFresh
                then (idx, gen', idx + 1)
                else
                    let (j, g'') =
                            randomR (0, pop - 1) gen'
                     in (j, g'', idx)
        (vRaw, gen''') = randomR (minUtxo, upper) gen''
        v = max minUtxo vRaw
        dest =
            Destination
                { destIndex = chosenIdx
                , destFresh = isFresh
                , destValue = Coin v
                }
     in (dest, idx', gen''')
