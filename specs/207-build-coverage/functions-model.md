# Functions model — #207

New or changed public signatures only. Names binding; internal helpers
are the commit owner's choice.

## P1 Columns

- H0 `encodeBuildCoverage :: (coverage :: BuildCoverage) -> ByteString`;
  `decodeBuildCoverage :: (bytes :: ByteString) -> Maybe BuildCoverage`
  (DM12; decode . encode = Just). May live in P2 if `BuildCoverage`
  must; placement is the owner's within `utxo-indexer-lib`.

## P2 Indexer

- H1 types `BuildCoverage { bcStartPoint :: Maybe (SlotNo, BlockHash), bcInterestSet :: InterestSet }`,
  `StoreCoverage = CoverageRecorded BuildCoverage | CoverageUnrecorded`,
  `BuildCoverageRefusal = BuildCoverageMismatch { recorded, requested :: BuildCoverage } | BuildCoverageUndecodable { raw :: ByteString, requested :: BuildCoverage }`
  with `Exception BuildCoverageRefusal`.
- H2 `IndexerHandle` gains
  `claimBuildCoverage :: BuildCoverage -> IO (Either BuildCoverageRefusal StoreCoverage)`.

## P3 Follower

- H3 `FollowerHandle` gains `fhStoreCoverage :: !StoreCoverage`.
- H4 `withChainSyncFollower` / `withChainSyncFollowerUsing`: signatures
  unchanged; throw `BuildCoverageRefusal` before chain-sync and before
  the action on refusal.

## P4 Disclosure

- H5 `CoverageStart` gains `StartUnknown`; `AddressCoverage` gains
  `AddressesUnknown`; `Limit` gains `CoverageUnknownLimit` (first in
  `Enum` order).
- H6 `storeCoverage :: (outcome :: StoreCoverage) -> Coverage`.

## P6 Daemon

- `followerCoverage` removed from the module and its exports.
