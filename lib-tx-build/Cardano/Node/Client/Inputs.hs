{- |
Module      : Cardano.Node.Client.Inputs
Description : Transaction input indexing helpers
License     : Apache-2.0

Helpers for concepts tied to transaction inputs.
-}
module Cardano.Node.Client.Inputs (
    spendingIndex,
) where

import Data.Set qualified as Set
import Data.Word (Word32)

import Cardano.Ledger.TxIn (TxIn)

{- | Compute the spending index of a 'TxIn' within
the sorted input set.

Plutus spending redeemers reference inputs by their
position in the sorted set of all transaction
inputs.
-}
spendingIndex :: TxIn -> Set.Set TxIn -> Word32
spendingIndex needle inputs =
    go 0 (Set.toAscList inputs)
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs
