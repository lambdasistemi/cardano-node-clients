# Functions model — #201

New or changed public signatures only. Names binding; argument names
document. Internal helpers are the commit owner's choice.

## N1 Disclosure

- G1 types: `Coverage`, `CoverageStart` (`FromOrigin` | `FromPoint SlotNo BlockHash`),
  `AddressCoverage` (`AllAddresses` | `FilteredAddresses`), `Disclosure`,
  `FreshnessStatus`, `Freshness`, `Limit` (DD1–DD5).
- G2 `assessFreshness :: (disclosure :: Disclosure) -> (now :: UTCTime) -> (ready :: ReadyStatus) -> (point :: SlotNo) -> Freshness`
- G3 `answerLimits :: (coverage :: Coverage) -> (freshness :: Freshness) -> [Limit]`

## N2 Server

- `ReadyStatus` (defined in N1, re-exported here) gains `rsLastProgress :: UTCTime` (DD6).
- `runServer :: (socketPath :: FilePath) -> (indexer :: IndexerHandle) -> (disclosure :: Disclosure) -> (getReady :: IO ReadyStatus) -> IO ()`

## N3 Daemon

- `DaemonConfig` gains `dcStaleAfterSeconds :: Word64`.
- G4 `followerCoverage :: (config :: ChainSyncConfig) -> Coverage`
- G5 `parseDaemonArgs :: (args :: [String]) -> Either String DaemonConfig`
  — the daemon's complete CLI parser; `Left` names the offending flag.
  `Main` keeps the usage text and exit; existing flags parse as before.
