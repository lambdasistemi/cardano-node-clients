{- |
Module      : Cardano.Node.Client.TxDiff.Resolver.N2C
Description : tx-diff resolver backed by a local cardano-node N2C 'Provider'
License     : Apache-2.0

A 'Resolver' that asks a local 'Provider' (see
"Cardano.Node.Client.Provider") for the currently-unspent UTxOs by 'TxIn'.
Resolution is best-effort: inputs that have already been spent on the
node's current chain tip will not be resolved, which is the expected
behavior documented for users running this resolver against a live node.

This module is intentionally tiny: it neither owns the node connection
nor the 'LSQChannel'. Callers (typically the tx-diff @Main@ wiring) build
a 'Provider', possibly inside a bracketed N2C client thread, and pass it
here.
-}
module Cardano.Node.Client.TxDiff.Resolver.N2C (
    n2cResolver,
) where

import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.TxDiff.Resolver (Resolver (..))

{- | Build an N2C-backed 'Resolver' from any 'Provider IO'.

The resolver's name is the literal string @"n2c"@. The resolver delegates
to 'queryUTxOByTxIn', which queries the acquired snapshot in one batch.
-}
n2cResolver :: Provider IO -> Resolver
n2cResolver provider =
    Resolver
        { resolverName = "n2c"
        , resolveInputs = queryUTxOByTxIn provider
        }
