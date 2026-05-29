{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.BlockExtract
Description : Treasury-neutral per-transaction payload and decoder seam
License     : Apache-2.0

The plug point that keeps transaction decoding /outside/ this
repository. The shared chain-sync follower extracts each block into a
list of 'BlockTx' — the raw, era-agnostic per-transaction bytes — and
hands them to a caller-supplied 'DecodeTx'. Downstream applications
(e.g. a treasury indexer) own the 'DecodeTx' and the meaning of any
'Cardano.Node.Client.TxHistoryIndexer.Types.TxRole' /
'Cardano.Node.Client.TxHistoryIndexer.Types.HistoryScope' it emits;
this library never interprets the bytes.

= Neutrality

'BlockTx' carries opaque bytes only. There is deliberately no scope,
role, redeemer, or any application-specific structure here: a
'DecodeTx' is free to parse the bytes however it likes and emit
'Cardano.Node.Client.TxHistoryIndexer.Types.TxSummaryEntry' values, or
'Nothing' for transactions it does not care about.
-}
module Cardano.Node.Client.TxHistoryIndexer.BlockExtract (
    -- * Per-transaction payload
    BlockTx (..),
    mkBlockTx,

    -- * Decoder seam
    DecodeTx,
) where

import Cardano.Node.Client.TxHistoryIndexer.Types (TxSummaryEntry)
import Data.ByteString (ByteString)

{- | Raw, treasury-neutral payload for a single transaction in a
block: the transaction's serialised bytes, exactly as carried on
chain. A 'DecodeTx' parses these bytes; this library never does.
-}
newtype BlockTx = BlockTx {unBlockTx :: ByteString}
    deriving stock (Eq, Show)

-- | Build a 'BlockTx' from a transaction's raw serialised bytes.
mkBlockTx :: ByteString -> BlockTx
mkBlockTx = BlockTx

{- | The decoder plug point. A downstream application supplies a
function that maps one transaction's raw bytes to the history entries
it wants persisted, or 'Nothing' if the transaction is irrelevant.

The decoder owns all application semantics; keeping it a function
type (rather than a class or concrete decoder) is what keeps decoding
out of this repository.
-}
type DecodeTx = BlockTx -> Maybe [TxSummaryEntry]
