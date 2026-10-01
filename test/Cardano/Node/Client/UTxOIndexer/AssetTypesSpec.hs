{- |
Module      : Cardano.Node.Client.UTxOIndexer.AssetTypesSpec
Description : Asset identity, composite key and inverse-op codecs
License     : Apache-2.0

Covers the asset identity and key codecs (policy IDs are exactly 28
bytes, asset names are 0..32 raw bytes with no text interpretation,
and the composite asset key layout keeps one asset's rows contiguous
under a prefix seek), and the rollback-log op encoding with the
provenance-carrying restore op (tag 2) beside the unchanged
pre-change tags.
-}
module Cardano.Node.Client.UTxOIndexer.AssetTypesSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Columns (
    decodeOps,
    encodeOps,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    AssetKey (..),
    AssetName (..),
    BlockHash (..),
    PolicyId (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
    assetKeyFromBytes,
    assetKeyToBytes,
    mkAssetName,
    mkPolicyId,
    slotToBytes,
    txInToBytes,
    unAssetName,
    unPolicyId,
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word8)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer asset types" $ do
        describe "mkPolicyId (DM1)" $ do
            it "accepts exactly 28 bytes" $ do
                mkPolicyId (BS.replicate 28 0xAB)
                    `shouldBe` Just (PolicyId (BS.replicate 28 0xAB))
            it "rejects 27 and 29 bytes" $ do
                mkPolicyId (BS.replicate 27 0xAB) `shouldBe` Nothing
                mkPolicyId (BS.replicate 29 0xAB) `shouldBe` Nothing
                mkPolicyId BS.empty `shouldBe` Nothing
            it "unPolicyId round-trips the raw bytes" $ do
                unPolicyId (PolicyId (BS.replicate 28 0x0F))
                    `shouldBe` BS.replicate 28 0x0F

        describe "mkAssetName (DM2)" $ do
            it "accepts empty and 32 raw bytes, rejects 33" $ do
                mkAssetName BS.empty `shouldBe` Just (AssetName BS.empty)
                mkAssetName (BS.replicate 32 0xFF)
                    `shouldBe` Just (AssetName (BS.replicate 32 0xFF))
                mkAssetName (BS.replicate 33 0xFF) `shouldBe` Nothing
            it "keeps non-UTF-8 bytes untouched" $ do
                let raw = BS.pack [0xC0, 0x80, 0xFF, 0xFE]
                unAssetName <$> mkAssetName raw `shouldBe` Just raw

        describe "assetKeyToBytes / assetKeyFromBytes (DM3)" $ do
            it "encodes policyId(28) || nameLen(1) || name || txIn(34)" $ do
                let name = BS.pack [0x61, 0x62]
                    key = AssetKey (PolicyId p28) (AssetName name) txin1
                    bytes = assetKeyToBytes key
                BS.length bytes `shouldBe` 28 + 1 + 2 + 34
                BS.take 28 bytes `shouldBe` p28
                BS.take 1 (BS.drop 28 bytes) `shouldBe` BS.pack [2]
                BS.drop 29 bytes `shouldBe` name <> txInToBytes txin1
            it "round-trips through assetKeyFromBytes" $ do
                assetKeyFromBytes (assetKeyToBytes sampleKey)
                    `shouldBe` Just sampleKey
            it "rejects trailing, truncated and over-long names" $ do
                let bytes = assetKeyToBytes sampleKey
                assetKeyFromBytes (bytes <> BS.singleton 0)
                    `shouldBe` Nothing
                assetKeyFromBytes (BS.init bytes) `shouldBe` Nothing
                assetKeyFromBytes BS.empty `shouldBe` Nothing
                -- A name length byte above 32 is not a valid asset.
                let badLen =
                        BS.concat
                            [ p28
                            , BS.pack [33]
                            , BS.replicate 33 0x61
                            , txInToBytes txin1
                            ]
                assetKeyFromBytes badLen `shouldBe` Nothing
            it "prefix never crosses into another name or policy" $ do
                let prefix = BS.concat [p28, BS.pack [3], "abc"]
                -- Same policy, longer name: no shared prefix.
                (BS.concat [p28, BS.pack [4], "abcd"] <> txInToBytes txin1)
                    `shouldSatisfy` not . BS.isPrefixOf prefix
                -- Same policy and name bytes, different policy: no
                -- shared prefix.
                (BS.concat [p28', BS.pack [3], "abc"] <> txInToBytes txin1)
                    `shouldSatisfy` not . BS.isPrefixOf prefix
            prop "round-trips generated keys" $
                forAll genAssetKey $ \key ->
                    assetKeyFromBytes (assetKeyToBytes key)
                        === Just key

        describe "rollback-log op encoding (DM9)" $ do
            it "tag-2 restore op round-trips with provenance" $ do
                let op =
                        UtxoRestore
                            txin1
                            addr
                            (TxOut "restore-bytes")
                            (SlotNo 77)
                            (BlockHash (BS.replicate 32 0x5A))
                decodeOps (encodeOps [op]) `shouldBe` Just [op]
            it "tag byte 2 distinguishes the restore op" $ do
                let op = UtxoRestore txin1 addr (TxOut "x") (SlotNo 1) bh32
                    encoded = encodeOps [op]
                -- Skip the 4-byte list length: the op tag byte is 2.
                BS.take 1 (BS.drop 4 encoded) `shouldBe` BS.pack [2]
            it "tag-0/1 ops keep their pre-change shape" $ do
                decodeOps (encodeOps [UtxoCreate txin1 addr (TxOut "c")])
                    `shouldBe` Just [UtxoCreate txin1 addr (TxOut "c")]
                decodeOps (encodeOps [UtxoSpend txin1])
                    `shouldBe` Just [UtxoSpend txin1]
            it "literal pre-change batch bytes decode (oracle: hand-built, not encodeOps)" $ do
                -- Tag 0 and tag 1 bytes as the pre-change binary
                -- wrote them, assembled by hand from the documented
                -- layout — independent of the codec under change.
                let createBytes =
                        BS.singleton 0
                            <> txInToBytes txin1
                            <> word32be (fromIntegral (BS.length addrBytes))
                            <> addrBytes
                            <> word32be (fromIntegral (BS.length outBytes))
                            <> outBytes
                    spendBytes = BS.singleton 1 <> txInToBytes txin2
                    batch = word32be 2 <> createBytes <> spendBytes
                decodeOps batch
                    `shouldBe` Just
                        [ UtxoCreate txin1 (Address addrBytes) (TxOut outBytes)
                        , UtxoSpend txin2
                        ]
                -- And the encoder reproduces the literal bytes
                -- exactly, for both directions of the oracle.
                encodeOps
                    [ UtxoCreate txin1 (Address addrBytes) (TxOut outBytes)
                    , UtxoSpend txin2
                    ]
                    `shouldBe` batch
            it "literal tag-2 restore bytes decode with provenance" $ do
                let restoreBytes =
                        BS.singleton 2
                            <> txInToBytes txin1
                            <> word32be (fromIntegral (BS.length addrBytes))
                            <> addrBytes
                            <> word32be (fromIntegral (BS.length outBytes))
                            <> outBytes
                            <> slotToBytes (SlotNo 77)
                            <> word32be 32
                            <> BS.replicate 32 0x5A
                decodeOps (word32be 1 <> restoreBytes)
                    `shouldBe` Just
                        [ UtxoRestore
                            txin1
                            (Address addrBytes)
                            (TxOut outBytes)
                            (SlotNo 77)
                            (BlockHash (BS.replicate 32 0x5A))
                        ]
            it "unknown tags are a decode failure" $ do
                let badOp =
                        BS.concat
                            [ BS.pack [3]
                            , txInToBytes txin1
                            , BS.pack [0, 0, 0, 29]
                            , BS.replicate 29 0xAA
                            ]
                decodeOps (BS.pack [0, 0, 0, 1] <> badOp) `shouldBe` Nothing

-- * Fixtures and generators

p28 :: ByteString
p28 = BS.replicate 28 0x11

p28' :: ByteString
p28' = BS.replicate 28 0x22

addr :: Address
addr = Address (BS.replicate 29 0xAA)

addrBytes :: ByteString
addrBytes = BS.replicate 29 0xAA

outBytes :: ByteString
outBytes = BS.pack [0xDE, 0xAD, 0xBE, 0xEF]

txin2 :: TxIn
txin2 = TxIn (BS.replicate 32 0xCD) 1

-- | Four-byte big-endian length prefix, as the op layout uses.
word32be :: Int -> ByteString
word32be w =
    BS.pack
        [ fromIntegral (w `div` 0x1000000) :: Word8
        , fromIntegral (w `div` 0x10000) :: Word8
        , fromIntegral (w `div` 0x100) :: Word8
        , fromIntegral w :: Word8
        ]

bh32 :: BlockHash
bh32 = BlockHash (BS.replicate 32 0x09)

txin1 :: TxIn
txin1 = TxIn (BS.replicate 32 0xAB) 7

sampleKey :: AssetKey
sampleKey =
    AssetKey
        (PolicyId p28)
        (AssetName (BS.pack [0x61, 0x62]))
        txin1

genByteString :: Int -> Int -> Gen ByteString
genByteString lo hi = do
    n <- chooseEnum (lo, hi)
    BS.pack <$> vectorOf n (arbitrary :: Gen Word8)

genAssetKey :: Gen AssetKey
genAssetKey = do
    p <- PolicyId . BS.pack <$> vectorOf 28 (arbitrary :: Gen Word8)
    n <- AssetName <$> genByteString 0 32
    tid <- BS.pack <$> vectorOf 32 (arbitrary :: Gen Word8)
    AssetKey p n . TxIn tid <$> arbitrary
