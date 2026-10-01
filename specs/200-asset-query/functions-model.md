# Functions model — #200

Only new or changed public signatures. Names are binding; argument
names are documentation. Internal helpers are the commit owner's choice.

## M1 Types

- F0a `mkPolicyId :: (bytes :: ByteString) -> Maybe PolicyId` — DM1.
- F0b `mkAssetName :: (bytes :: ByteString) -> Maybe AssetName` — DM2.
- F0c `unPolicyId`, `unAssetName` — raw bytes back.
- F0d `assetKeyToBytes :: AssetKey -> ByteString`,
  `assetKeyFromBytes :: ByteString -> Maybe AssetKey` — DM3.

## M2 TxOutView

- F1 `decodeTxOutView :: (stored :: TxOut) -> Either TxOutViewError TxOutView`
  where `TxOutView` exposes the DM4 asset list and the DM5 datum view.
  Pure, total over the input bytes.

## M3 IndexerOp

- `UtxoOp` gains constructor `UtxoRestore !TxIn !Address !TxOut !SlotNo !BlockHash` (DM6).

## M5 Indexer

- F2 `IndexerHandle` gains field
  `assetUtxos :: PolicyId -> AssetName -> IO (Either AssetQueryUnavailable AssetSnapshot)`.
  Reads everything in one transaction. Existing fields unchanged.
- F3 `data AssetSnapshot = AssetSnapshot { asPoint :: (SlotNo, BlockHash), asMatches :: [AssetMatch] }`
  `data AssetMatch = AssetMatch { amTxIn :: TxIn, amTxOut :: TxOut, amQuantity :: Word64, amCreatedSlot :: SlotNo, amCreatedBlockHash :: BlockHash }`
- F4 `data AssetQueryUnavailable = AssetIndexAbsent | NoIndexedPoint | AssetIndexInconsistent TxIn`
- Existing constructors `withInMemoryIndexer[Runner]`,
  `withRocksDBIndexer[Runner]` keep their signatures; RocksDB opening
  creates missing column families.

## M6 Server (S2)

- `runServer` keeps its signature. The request sum gains the asset
  request; responses follow the spec.md wire schema.
