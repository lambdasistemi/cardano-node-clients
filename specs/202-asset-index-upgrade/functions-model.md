# Functions model — #202

Only new or changed public signatures. Existing constructors keep their
signatures and their behaviour (no upgrade).

## M2 Indexer

- F1 `data OpenOptions = OpenOptions { ooRebuildAssetIndex :: Bool }`
  and `defaultOpenOptions :: OpenOptions` (request off).
- F2 `withRocksDBIndexerWith :: (options :: OpenOptions) -> (path :: FilePath) -> (IndexerHandle -> IO a) -> IO a`
- F3 `withRocksDBIndexerRunnerWith :: (options :: OpenOptions) -> (path :: FilePath) -> (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) -> IO a`
  The existing `withRocksDBIndexer[Runner]` equal these with
  `defaultOpenOptions`.
- F4 `AssetQueryUnavailable` gains constructor `AssetIndexRebuilding`.

## M1 ColumnFamilies (internal)

- F5 `createColumnFamilies :: (db :: DB) -> (families :: [(String, Config)]) -> IO ()`
  creates each named family on an open handle and releases the created
  handles; a RocksDB error raises an `IOException` naming the family.

## M5 Daemon (S2)

- F6 `DaemonConfig` gains `dcRebuildAssetIndex :: Bool`.
