{- |
Module      : Cardano.Node.Client.TxGenerator.Selection
Description : Source-UTxO picking from the population
License     : Apache-2.0

Pure logic for the @transact@ arm's source selection
(per @specs/034-cardano-tx-generator/data-model.md§Source UTxO@):
sample an HD index uniformly from @[0, nextHDIndex)@ using
the request seed's 'StdGen'; ask whether that index has a
viable UTxO; on a "no", advance the same RNG stream and
retry up to @maxRetries@ times; on cap-hit, return
'Nothing' so the daemon can map it to
@no-pickable-source@ (FR-006).

The viability predicate is supplied by the caller. The
daemon's wiring closes over @snapshotAt@ + the K-output
floor; tests close over an in-memory @Map Word64 Bool@.
The function is otherwise oblivious to ledger types — the
'IO' is only there because the predicate may need it.
-}
module Cardano.Node.Client.TxGenerator.Selection (
    pickSourceIndex,
    verifyInputsUnspent,
) where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Word (Word32, Word64)
import System.Random (Random (random), StdGen)

import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (Provider (..))

{- | Repeatedly draw an index from the request's RNG
stream and call the viability predicate. Returns the
first viable index (and the RNG state at that point so
the caller can keep using the same deterministic stream
for downstream sampling), or 'Nothing' after
@maxRetries@ unsuccessful draws.

Total RNG draws on a successful pick is between 1 and
@maxRetries + 1@ — every call site reads the same number
of words for the same seed/state pair, so determinism
(FR-002 / SC-002) is preserved.

If @nextHDIndex@ is zero (cold-start population) the
predicate is never called and 'Nothing' is returned
immediately.
-}
pickSourceIndex ::
    -- | viability predicate — @True@ if the address at
    --     this index has a UTxO that meets the K-output
    --     floor.
    (Word64 -> IO Bool) ->
    -- | exclusive upper bound on the population
    --     (== current next-HD-index).
    Word64 ->
    -- | retries cap. After this many @False@ results the
    --     function returns 'Nothing'.
    Word32 ->
    -- | request RNG state.
    StdGen ->
    -- | @Just (index, gen')@ on success, where @gen'@ is
    --     the RNG state advanced past the successful
    --     draw. 'Nothing' on retry-cap or zero-population.
    IO (Maybe (Word64, StdGen))
pickSourceIndex viable population maxRetries gen0
    | population == 0 = pure Nothing
    | otherwise = go 0 gen0
  where
    go :: Word32 -> StdGen -> IO (Maybe (Word64, StdGen))
    go attempts gen
        | attempts > maxRetries = pure Nothing
        | otherwise = do
            let (w, gen') = random gen :: (Word64, StdGen)
                idx = w `mod` population
            ok <- viable idx
            if ok
                then pure (Just (idx, gen'))
                else go (attempts + 1) gen'

{- | Pre-submit chain-tip probe. Returns 'True' when every
input in the supplied set is still unspent at the relay's
current chain tip, 'False' when at least one input is missing.

One LSQ round-trip via 'queryUTxOByTxIn'. Raises
'Cardano.Node.Client.N2C.Types.ConnectionLost' on bearer
failure (propagated from the underlying query); callers
catch this exception at the arm level and map it to
@IndexNotReady@.

Empty input set is vacuously 'True' — there is nothing to
verify.
-}
verifyInputsUnspent :: Provider IO -> Set TxIn -> IO Bool
verifyInputsUnspent p inputs = do
    found <- queryUTxOByTxIn p inputs
    pure (Map.keysSet found == inputs)
