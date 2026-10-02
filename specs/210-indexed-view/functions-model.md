# Functions model v1 — #210

Names/signatures below are proposed for intake acceptance. Internal helpers
belong to the commit owner; a public signature challenge returns to planning.

## M210-1 / S1

- F210-1: `IndexerHandle` gains
  `readView :: (queries :: NonEmpty ReadQuery) -> IO (Either AssetQueryUnavailable IndexedView)`.
  Atomic point/completeness/results/provenance read; no independent public IO
  reads composed internally. Materialized result independent of store lifetime.
- F210-2: export D210-1/2/3 query, result and view types with Haddock.
  Existing `snapshotAt`, `assetUtxos` and constructors retain signatures.

## M210-2 / S2

- F210-3: `runServer` and existing public server entry points retain their
  signatures. The request sum gains a point-bound batch request; response
  and error shapes bind D210-5/6. Exact wire contract frozen before S2 dispatch.
- No public historical-state query or API returning a live storage snapshot.
