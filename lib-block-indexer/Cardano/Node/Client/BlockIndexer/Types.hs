{- |
Module      : Cardano.Node.Client.BlockIndexer.Types
Description : Reserved public namespace for shared block-indexer types
License     : Apache-2.0

Reserved namespace for types shared across the
@cardano-node-clients:block-indexer@ sublibrary.

The module is intentionally empty for now. It remains exposed so
downstream packages can depend on a stable module layout while the
generic split evolves. Concrete domains should keep their own types
in their own packages; for example the UTxO indexer keeps
@InterestSet@, @UtxoOp@, and column definitions under
@Cardano.Node.Client.UTxOIndexer.*@ instead of exporting them here.
-}
module Cardano.Node.Client.BlockIndexer.Types ()
where
