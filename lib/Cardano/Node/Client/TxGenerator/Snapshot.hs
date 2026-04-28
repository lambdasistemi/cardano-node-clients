{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Snapshot
Description : Population-wide UTxO percentile aggregation
License     : Apache-2.0

Builds the @snapshot@ response payload (per
@specs/034-cardano-tx-generator/data-model.md§Snapshot@):

* Walk every population address from index 0 to
  @nextHDIndex - 1@.
* For each address, query the embedded indexer's
  @snapshotAt@ for the raw @(TxIn, TxOut)@ pairs.
* Decode each indexer @TxOut@ (raw Conway CBOR) into a
  ledger @TxOut ConwayEra@ to extract the lovelace
  value.
* Flatten across all addresses to a single @[Coin]@,
  sort, and pick the p10 / p50 / p90 percentiles using
  the nearest-rank method.

This is a hot validator path — the composer's
@eventually_population_grew@-shaped commands fire it
regularly. It must not go through LSQ-by-address; the
embedded indexer is the only authoritative read source.

CBOR decoding uses the indexer's encode-side contract:
the bytes are @serialize' (eraProtVerLow \@ConwayEra)@
output (see
@Cardano.Node.Client.UTxOIndexer.BlockExtract.mkCreate@),
and we mirror that here with the same protocol version.
-}
module Cardano.Node.Client.TxGenerator.Snapshot (
    -- * Aggregate
    collectPopulationValues,

    -- * Percentiles
    percentiles,

    -- * Decode helpers (exposed for tests)
    decodeIdxTxOut,
) where

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Binary qualified as LB
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TxOut, eraProtVerLow)
import Cardano.Node.Client.TxGenerator.Population (deriveAddr)
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Idx
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Lens.Micro ((^.))

{- | Walk every population address @[0, nextHDIndex)@,
query the indexer for its UTxOs, decode each TxOut, and
collect the lovelace values. Decoding errors are
silently dropped; the daemon's invariant is that every
population UTxO comes from the indexer's own block
extractor, so a decode failure indicates a serious
internal bug — but we degrade gracefully so a single
malformed entry does not poison the whole snapshot.
-}
collectPopulationValues ::
    IndexerHandle ->
    Network ->
    ByteString ->
    Word64 ->
    IO [Coin]
collectPopulationValues idx net masterSeed populationSize
    | populationSize == 0 = pure []
    | otherwise = do
        valuesPerAddr <-
            mapM
                (queryAddrValues idx net masterSeed)
                [0 .. populationSize - 1]
        pure (concat valuesPerAddr)

queryAddrValues ::
    IndexerHandle ->
    Network ->
    ByteString ->
    Word64 ->
    IO [Coin]
queryAddrValues idx net masterSeed i = do
    let addr = deriveAddr net masterSeed i
        idxAddr = Idx.Address (serialiseAddr addr)
    utxos <- snapshotAt idx idxAddr
    pure
        [ value
        | (_, txOut) <- utxos
        , Right ledgerOut <- [decodeIdxTxOut txOut]
        , let value = ledgerOut ^. coinTxOutL
        ]

{- | Decode an indexer @TxOut@'s raw CBOR bytes back into
a ledger @TxOut ConwayEra@. The encode side lives in
@Cardano.Node.Client.UTxOIndexer.BlockExtract.mkCreate@.
-}
decodeIdxTxOut ::
    Idx.TxOut ->
    Either Text (TxOut ConwayEra)
decodeIdxTxOut (Idx.TxOut bytes) =
    case LB.decodeFullDecoder
        (eraProtVerLow @ConwayEra)
        "TxOut"
        LB.decCBOR
        (LBS.fromStrict bytes) of
        Right out -> Right out
        Left err -> Left (Text.pack (show err))

{- | The p10, p50, p90 percentiles of a list of 'Coin'
values using the nearest-rank method:
@idx_p = ceil(p/100 * n) - 1@ on the sorted list, clamped
to @[0, n-1]@. Returns 'Nothing' on the empty list.
-}
percentiles ::
    [Coin] -> Maybe (Coin, Coin, Coin)
percentiles [] = Nothing
percentiles cs =
    let sorted = sort cs
        n = length sorted
        pick p =
            sorted
                !! min
                    (n - 1)
                    ( max
                        0
                        ( ceiling
                            ( (fromIntegral p :: Double)
                                / 100
                                * fromIntegral n
                            )
                            - 1
                        )
                    )
     in Just (pick (10 :: Int), pick 50, pick 90)
