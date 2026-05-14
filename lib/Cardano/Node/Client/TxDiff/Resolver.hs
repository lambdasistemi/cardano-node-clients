{- |
Module      : Cardano.Node.Client.TxDiff.Resolver
Description : Pluggable input-resolver chain for tx-diff
License     : Apache-2.0

A 'Resolver' turns a set of 'TxIn's into a partial map of resolved Conway
'TxOut's. 'resolveChain' runs several resolvers in order, each one only
seeing the inputs that the previous resolvers could not resolve, and
returns the union of resolved entries plus the list of resolver names that
failed to find each still-unresolved input.

The diff core consumes only the resolved map via
'Cardano.Node.Client.TxDiff.TxDiffOptions.txDiffResolvedInputs'. The CLI is
responsible for invoking 'resolveChain' before computing the diff and for
turning unresolved entries into stderr diagnostics.
-}
module Cardano.Node.Client.TxDiff.Resolver (
    Resolver (..),
    resolveChain,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)

{- | A named resolver. The function is given the set of inputs still in
need of resolution and returns whatever it could resolve. The result map
MAY be a strict subset of the input set; missing keys are treated as
"this resolver could not resolve that input".
-}
data Resolver = Resolver
    { resolverName :: Text
    , resolveInputs :: Set TxIn -> IO (Map TxIn (TxOut ConwayEra))
    }

{- | Run a list of resolvers in order. Each resolver sees only the inputs
the previous resolvers could not resolve. Returns @(resolved, tried)@
where @resolved@ is the merged map and @tried@ maps each still-unresolved
input to the resolver names that were asked and failed (in order).

The empty chain returns @(Map.empty, Map.fromSet (const []) inputs)@.
-}
resolveChain ::
    [Resolver] ->
    Set TxIn ->
    IO (Map TxIn (TxOut ConwayEra), Map TxIn [Text])
resolveChain = go Map.empty []
  where
    go acc askedSoFar [] remaining =
        pure (acc, Map.fromSet (const askedSoFar) remaining)
    go acc _ _ remaining
        | Set.null remaining =
            pure (acc, Map.empty)
    go acc askedSoFar (resolver : rest) remaining = do
        found <- resolveInputs resolver remaining
        let resolvedSet = Map.keysSet found
            newRemaining = Set.difference remaining resolvedSet
            newAcc = Map.union acc found
            newAsked = askedSoFar <> [resolverName resolver]
        go newAcc newAsked rest newRemaining
