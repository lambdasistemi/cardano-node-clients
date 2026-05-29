{-# LANGUAGE GADTs #-}

{- |
Module      : Cardano.Node.Client.TxHistoryIndexer.Columns
License     : Apache-2.0
Description : Typed-column GADT for the tx-history indexer database

Database layout for the multi-tenant tx-history indexer expressed
against the 'Database.KV.Transaction' abstraction from
@kv-transactions@.

One column:

* 'HistoryCol' :: @KV TxSummaryKey ByteString@ — entries filed
  under the ordered composite key
  @lenTenant || tenant || lenScope || scope || slotBE || txid ||
  role@ (see "Cardano.Node.Client.TxHistoryIndexer.Types"), so a
  cursor seek to 'scopePrefix' yields every entry of one
  @(tenant, scope)@ in @(slot, txid, role)@ order. The value is
  the opaque payload blob, stored verbatim.

Both the in-memory and RocksDB backends share these column
definitions verbatim — the backend choice happens at the
'Database.KV.InMemory' / 'Database.KV.RocksDB' boundary, not here.
-}
module Cardano.Node.Client.TxHistoryIndexer.Columns (
    -- * Column GADT
    Cols (..),

    -- * Codecs
    historyCodecs,
    historyColCodecs,
) where

import Cardano.Node.Client.TxHistoryIndexer.Types (
    TxSummaryKey,
    summaryKeyFromBytes,
    summaryKeyToBytes,
 )
import Control.Lens (Prism', prism')
import Data.ByteString (ByteString)
import Data.Dependent.Map (DMap)
import Data.GADT.Compare (
    GCompare (..),
    GEq (..),
    GOrdering (..),
 )
import Data.Type.Equality (type (:~:) (Refl))
import Database.KV.Transaction (
    Codecs (..),
    DSum ((:=>)),
    KV,
    fromList,
 )

-- | The tx-history indexer database's column families.
data Cols c where
    -- | Entries table: @TxSummaryKey → payload@. Key is the
    -- ordered composite key; a cursor prefix-scan by
    -- 'Cardano.Node.Client.TxHistoryIndexer.Types.scopePrefix'
    -- yields every entry of one @(tenant, scope)@ in
    -- @(slot, txid, role)@ order.
    HistoryCol :: Cols (KV TxSummaryKey ByteString)

instance GEq Cols where
    geq HistoryCol HistoryCol = Just Refl

instance GCompare Cols where
    gcompare HistoryCol HistoryCol = GEQ

-- | Codecs for 'HistoryCol'.
historyColCodecs :: Codecs (KV TxSummaryKey ByteString)
historyColCodecs =
    Codecs
        { keyCodec = summaryKeyPrism
        , valueCodec = payloadPrism
        }

-- | The full column-codec map for the tx-history database.
historyCodecs :: DMap Cols Codecs
historyCodecs = fromList [HistoryCol :=> historyColCodecs]

-- Internal --------------------------------------------------------

summaryKeyPrism :: Prism' ByteString TxSummaryKey
summaryKeyPrism = prism' encode summaryKeyFromBytes
  where
    encode k = case summaryKeyToBytes k of
        Just bs -> bs
        Nothing ->
            error
                "summaryKeyPrism: tenant or scope exceeds 255 \
                \bytes — invariant violation"

payloadPrism :: Prism' ByteString ByteString
payloadPrism = prism' id Just
