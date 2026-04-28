{- |
Module      : Cardano.Node.Client.TxGenerator.Snapshot
Description : Population-wide UTxO percentile aggregation
License     : Apache-2.0

Stub for T002. Populated in T013 with @computeSnapshot@ —
walks the population, queries the embedded indexer's
@snapshotAt@, computes p10/p50/p90 of UTxO values.
-}
module Cardano.Node.Client.TxGenerator.Snapshot () where
