{- |
Module      : Cardano.Node.Client.UTxOIndexer.TypesSpec
Description : Round-trip tests for the indexer's composite-key codec
License     : Apache-2.0

Locks the on-disk byte form of 'AddrKey' so a future
backend swap (in-memory → RocksDB) cannot silently
break already-indexed data, and exercises the address
length-prefix invariant.
-}
module Cardano.Node.Client.UTxOIndexer.TypesSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    TxIn (..),
    addrKeyFromBytes,
    addrKeyToBytes,
    addressPrefix,
    txInFromBytes,
    txInToBytes,
 )
import Data.ByteString qualified as BS
import Data.Word (Word16, Word8)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.QuickCheck (
    Arbitrary (..),
    Gen,
    choose,
    property,
    vectorOf,
    (===),
 )

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer.Types" $ do
    describe "AddrKey codec" $ do
        it "round-trips for a Shelley-shaped key (29-byte address)" $ do
            let addr = Address (BS.replicate 29 0x42)
                tid = BS.replicate 32 0xAA
                ix = 7 :: Word16
                key = AddrKey addr (TxIn tid ix)
            (addrKeyFromBytes =<< addrKeyToBytes key) `shouldBe` Just key

        it "round-trips for a Byron-shaped key (typical 60-byte address)" $ do
            let addr = Address (BS.replicate 60 0x33)
                tid = BS.replicate 32 0xCC
                ix = 0 :: Word16
                key = AddrKey addr (TxIn tid ix)
            (addrKeyFromBytes =<< addrKeyToBytes key) `shouldBe` Just key

        it "round-trips for a key with a 0-length address" $ do
            let addr = Address BS.empty
                tid = BS.replicate 32 0x00
                ix = 0 :: Word16
                key = AddrKey addr (TxIn tid ix)
            (addrKeyFromBytes =<< addrKeyToBytes key) `shouldBe` Just key

        it "rejects keys whose address exceeds 255 bytes" $ do
            let addr = Address (BS.replicate 256 0x00)
                tid = BS.replicate 32 0x00
                key = AddrKey addr (TxIn tid 0)
            addrKeyToBytes key `shouldBe` Nothing

        it "decodes nothing for truncated input" $ do
            addrKeyFromBytes BS.empty `shouldBe` Nothing
            addrKeyFromBytes (BS.singleton 5) `shouldBe` Nothing

        it "decodes nothing for trailing garbage" $ do
            let addr = Address (BS.replicate 29 0x11)
                tid = BS.replicate 32 0x22
            case addrKeyToBytes (AddrKey addr (TxIn tid 0)) of
                Just bs ->
                    addrKeyFromBytes (bs <> BS.singleton 0xFF)
                        `shouldBe` Nothing
                Nothing -> fail "addrKeyToBytes returned Nothing"

        it "encode/decode is total on Arbitrary keys (≤255-byte addrs)" $
            property $
                \(SmallishAddrKey k) ->
                    (addrKeyFromBytes =<< addrKeyToBytes k) === Just k

    describe "addressPrefix" $ do
        it "is the strict byte prefix of any AddrKey at that address" $ do
            let addr = Address (BS.replicate 29 0x55)
                tid = BS.replicate 32 0x66
                key = AddrKey addr (TxIn tid 13)
            case (addrKeyToBytes key, addressPrefix addr) of
                (Just keyBytes, Just pfx) ->
                    BS.take (BS.length pfx) keyBytes `shouldBe` pfx
                _ -> fail "encode returned Nothing"

        it "differs in the length byte for two addresses of different lengths" $ do
            case ( addressPrefix (Address (BS.replicate 29 0x77))
                 , addressPrefix (Address (BS.replicate 60 0x77))
                 ) of
                (Just p29, Just p60) -> do
                    BS.head p29 `shouldBe` 29
                    BS.head p60 `shouldBe` 60
                _ -> fail "addressPrefix returned Nothing"

    describe "TxIn codec" $ do
        it "round-trips a concrete TxIn" $ do
            let tin = TxIn (BS.replicate 32 0x42) 17
            (txInFromBytes . txInToBytes) tin `shouldBe` Just tin

        it "round-trips ix=0 and ix=maxBound" $ do
            let mk = TxIn (BS.replicate 32 0xFF)
            (txInFromBytes . txInToBytes) (mk 0) `shouldBe` Just (mk 0)
            (txInFromBytes . txInToBytes) (mk maxBound)
                `shouldBe` Just (mk maxBound)

        it "encodes to exactly 34 bytes" $ do
            BS.length (txInToBytes (TxIn (BS.replicate 32 0) 0))
                `shouldBe` 34
            BS.length (txInToBytes (TxIn (BS.replicate 32 0xFF) 0xFFFF))
                `shouldBe` 34

        it "decodes nothing for non-34-byte input" $ do
            txInFromBytes BS.empty `shouldBe` Nothing
            txInFromBytes (BS.replicate 33 0) `shouldBe` Nothing
            txInFromBytes (BS.replicate 35 0) `shouldBe` Nothing

-- Generators ------------------------------------------------------

{- | An 'AddrKey' with an address length in @[0, 255]@.
We never observe larger addresses from the ledger.
-}
newtype SmallishAddrKey = SmallishAddrKey AddrKey
    deriving stock (Show)

instance Arbitrary SmallishAddrKey where
    arbitrary = do
        addrLen <- choose (0, 255)
        addr <- BS.pack <$> bytes addrLen
        tid <- BS.pack <$> bytes 32
        SmallishAddrKey . AddrKey (Address addr) . TxIn tid
            <$> arbitrary
      where
        bytes :: Int -> Gen [Word8]
        bytes = flip vectorOf arbitrary
