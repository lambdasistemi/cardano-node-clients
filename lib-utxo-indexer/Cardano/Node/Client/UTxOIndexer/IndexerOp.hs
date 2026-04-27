{- |
Module      : Cardano.Node.Client.UTxOIndexer.IndexerOp
Description : The 'UtxoOp' create\/spend sum
License     : Apache-2.0

Defined in its own module so
'Cardano.Node.Client.UTxOIndexer.Columns' can reference
the 'UtxoOp' constructors in the rollback-column codec
without importing
'Cardano.Node.Client.UTxOIndexer.Indexer' (which imports
'Cardano.Node.Client.UTxOIndexer.Columns' for the
typed-column GADT). Re-exported by the @Indexer@ module
so the public surface is unchanged.
-}
module Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
) where

import Cardano.Node.Client.UTxOIndexer.Types (
    Address,
    TxIn,
    TxOut,
 )

{- | A single mutation against the indexer's live state.
Apply-block expands a chain block into a list of these.
-}
data UtxoOp
    = -- | Create the UTxO @(txIn, addr, txOut)@:
      -- insert into both 'TxInCol' (txIn → addr) and
      -- 'AddressIndex' ((addr, txIn) → txOut).
      UtxoCreate !TxIn !Address !TxOut
    | -- | Spend the UTxO at @txIn@: look up its address
      -- via 'TxInCol', delete from both columns. No-op if
      -- the TxIn is not in the index.
      UtxoSpend !TxIn
    deriving stock (Eq, Show)
