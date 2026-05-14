{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxDiff.Web2Spec
Description : Web2 (Blockfrost-style) resolver tests against a canned fetcher
-}
module Cardano.Node.Client.TxDiff.Web2Spec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Lens.Micro ((^.))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Cardano.Crypto.Hash (hashFromStringAsHex)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxDiff.Resolver (Resolver (..), resolveChain)
import Cardano.Node.Client.TxDiff.Resolver.Web2 (
    Web2Config (..),
    Web2FetchError (..),
    web2Resolver,
 )

spec :: Spec
spec =
    describe "Web2 (Blockfrost-style) resolver" $ do
        it "resolves an input by indexing into the fetched tx's outputs" $ do
            tx <- loadFixture
            let cbor = fixtureCbor
                fetcher _ = pure (Right cbor)
                cfg =
                    Web2Config
                        { web2ResolverName = "web2"
                        , web2Fetch = fetcher
                        }
                resolver = web2Resolver cfg
                txIn = TxIn (mkTxId 0) (TxIx 0)
            result <- resolveInputs resolver (Set.singleton txIn)
            case toList (tx ^. bodyTxL . outputsTxBodyL) of
                [] ->
                    expectationFailure "fixture transaction has no outputs"
                expected : _ ->
                    Map.lookup txIn result
                        `shouldSatisfy` matchesAddress expected

        it "issues exactly one fetch per distinct TxId when several inputs share it" $ do
            callCount <- newIORef (0 :: Int)
            let cbor = fixtureCbor
                fetcher _ = do
                    modifyIORef' callCount (+ 1)
                    pure (Right cbor)
                cfg =
                    Web2Config
                        { web2ResolverName = "web2"
                        , web2Fetch = fetcher
                        }
                resolver = web2Resolver cfg
                txId = mkTxId 0
                inputs =
                    Set.fromList
                        [ TxIn txId (TxIx 0)
                        , TxIn txId (TxIx 1)
                        ]
            _ <- resolveInputs resolver inputs
            readIORef callCount `shouldReturn` 1

        it "treats HTTP failures as misses without raising" $ do
            let fetcher _ =
                    pure (Left (Web2FetchHttpError "boom"))
                cfg =
                    Web2Config
                        { web2ResolverName = "web2"
                        , web2Fetch = fetcher
                        }
                resolver = web2Resolver cfg
                inputs = Set.fromList [TxIn (mkTxId 0) (TxIx 0)]
            (resolved, unresolved) <- resolveChain [resolver] inputs
            Map.keysSet resolved `shouldBe` Set.empty
            unresolved
                `shouldBe` Map.fromList
                    [(TxIn (mkTxId 0) (TxIx 0), ["web2"])]

        it "treats undecodable CBOR as misses without raising" $ do
            let fetcher _ =
                    pure (Right (BS8.pack "not-cbor"))
                cfg =
                    Web2Config
                        { web2ResolverName = "web2"
                        , web2Fetch = fetcher
                        }
                resolver = web2Resolver cfg
                inputs = Set.fromList [TxIn (mkTxId 0) (TxIx 0)]
            (resolved, _unresolved) <- resolveChain [resolver] inputs
            Map.keysSet resolved `shouldBe` Set.empty

        it "skips inputs whose TxIx is past the tx's output range" $ do
            let cbor = fixtureCbor
                fetcher _ = pure (Right cbor)
                cfg =
                    Web2Config
                        { web2ResolverName = "web2"
                        , web2Fetch = fetcher
                        }
                resolver = web2Resolver cfg
                outOfRange = TxIn (mkTxId 0) (TxIx 9999)
            result <- resolveInputs resolver (Set.singleton outOfRange)
            Map.lookup outOfRange result `shouldBe` Nothing

matchesAddress ::
    TxOut ConwayEra -> Maybe (TxOut ConwayEra) -> Bool
matchesAddress _ Nothing = False
matchesAddress expected (Just got) =
    expected ^. addrTxOutL == got ^. addrTxOutL

fixturePath :: FilePath
fixturePath =
    "test/fixtures/mainnet-txbuild/"
        <> "789f9a1393e3c9eacd19582ebb1b02b777696c8ddcedda2d8752cb5723c42ef6"
        <> ".cbor.hex"

fixtureHexText :: Text
fixtureHexText =
    unsafePerformIO (Text.strip . Text.pack <$> readFile fixturePath)
{-# NOINLINE fixtureHexText #-}

fixtureCbor :: ByteString
fixtureCbor =
    case Base16.decode (Text.encodeUtf8 fixtureHexText) of
        Right raw -> raw
        Left err -> error ("Web2Spec: fixtureCbor base16 decode failed: " <> err)

loadFixture :: IO ConwayTx
loadFixture =
    case decodeFullAnnotatorFromHexText
        (natVersion @11)
        "Web2Spec fixture"
        (decCBOR :: forall s. Decoder s (Annotator ConwayTx))
        fixtureHexText of
        Right tx -> pure tx
        Left err -> fail ("Web2Spec.loadFixture: " <> show err)

mkTxId :: Int -> TxId
mkTxId n =
    let hexStr =
            replicate 60 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in TxId (unsafeMakeSafeHash h)

hexByte :: Int -> String
hexByte x =
    let s = "0123456789abcdef"
     in [s !! (x `div` 16), s !! (x `mod` 16)]
