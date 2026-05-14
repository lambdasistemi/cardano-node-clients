{- |
Module      : Cardano.Node.Client.TxDiff.ResolverSpec
Description : Resolver chain semantics
-}
module Cardano.Node.Client.TxDiff.ResolverSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Test.Hspec

import Cardano.Crypto.Hash (hashFromStringAsHex)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Credential (Credential (KeyHashObj), StakeReference (StakeRefNull))
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (Payment))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Cardano.Node.Client.TxDiff.Resolver (Resolver (..), resolveChain)

spec :: Spec
spec =
    describe "Resolver chain" $ do
        it "returns empty maps when the chain is empty and there are no inputs" $ do
            (resolved, unresolved) <- resolveChain [] Set.empty
            Map.keysSet resolved `shouldBe` Set.empty
            unresolved `shouldBe` Map.empty

        it "marks every input as not tried by any resolver when the chain is empty" $ do
            let inputs = Set.fromList [mkTxIn 1, mkTxIn 2]
            (resolved, unresolved) <- resolveChain [] inputs
            Map.keysSet resolved `shouldBe` Set.empty
            unresolved `shouldBe` Map.fromList [(mkTxIn 1, []), (mkTxIn 2, [])]

        it "uses a single resolver and reports it as the only tried resolver for misses" $ do
            let inputs = Set.fromList [mkTxIn 1, mkTxIn 2]
                resolver = fakeResolver "alpha" (Map.singleton (mkTxIn 1) (mkTestTxOut 100))
            (resolved, unresolved) <- resolveChain [resolver] inputs
            Map.keysSet resolved `shouldBe` Set.singleton (mkTxIn 1)
            unresolved `shouldBe` Map.singleton (mkTxIn 2) ["alpha"]

        it "asks each later resolver only for inputs earlier resolvers could not resolve" $ do
            seen <- newIORef ([] :: [(Text, Set TxIn)])
            let inputs = Set.fromList [mkTxIn 1, mkTxIn 2, mkTxIn 3]
                alpha =
                    Resolver
                        { resolverName = "alpha"
                        , resolveInputs = \req -> do
                            modifyIORef' seen (("alpha", req) :)
                            pure (Map.singleton (mkTxIn 1) (mkTestTxOut 1))
                        }
                beta =
                    Resolver
                        { resolverName = "beta"
                        , resolveInputs = \req -> do
                            modifyIORef' seen (("beta", req) :)
                            pure (Map.singleton (mkTxIn 2) (mkTestTxOut 2))
                        }
            (resolved, unresolved) <- resolveChain [alpha, beta] inputs
            log_ <- reverse <$> readIORef seen
            map fst log_ `shouldBe` ["alpha", "beta"]
            map snd log_
                `shouldBe` [ inputs
                           , Set.fromList [mkTxIn 2, mkTxIn 3]
                           ]
            Map.keysSet resolved
                `shouldBe` Set.fromList [mkTxIn 1, mkTxIn 2]
            unresolved
                `shouldBe` Map.singleton (mkTxIn 3) ["alpha", "beta"]

        it "skips later resolvers once nothing remains to resolve" $ do
            secondCalled <- newIORef False
            let inputs = Set.singleton (mkTxIn 1)
                alpha =
                    fakeResolver "alpha" (Map.singleton (mkTxIn 1) (mkTestTxOut 1))
                beta =
                    Resolver
                        { resolverName = "beta"
                        , resolveInputs = \_ -> do
                            modifyIORef' secondCalled (const True)
                            pure Map.empty
                        }
            (resolved, unresolved) <- resolveChain [alpha, beta] inputs
            Map.keysSet resolved `shouldBe` Set.singleton (mkTxIn 1)
            unresolved `shouldBe` Map.empty
            readIORef secondCalled
                `shouldReturn` False

fakeResolver :: Text -> Map TxIn (TxOut ConwayEra) -> Resolver
fakeResolver name results =
    Resolver
        { resolverName = name
        , resolveInputs = pure . Map.restrictKeys results
        }

mkTxIn :: Int -> TxIn
mkTxIn n =
    let hexStr =
            replicate 60 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in TxIn
            (TxId (unsafeMakeSafeHash h))
            (TxIx 0)

mkTestTxOut :: Int -> TxOut ConwayEra
mkTestTxOut n =
    mkBasicTxOut (mkTestAddr n) (MaryValue (Coin (fromIntegral n)) (MultiAsset mempty))

mkTestAddr :: Int -> Addr
mkTestAddr n =
    let hexStr =
            replicate 52 '0'
                ++ hexByte (n `div` 256)
                ++ hexByte (n `mod` 256)
        h = fromJust (hashFromStringAsHex hexStr)
     in Addr
            Testnet
            (KeyHashObj (KeyHash h :: KeyHash Payment))
            StakeRefNull

hexByte :: Int -> String
hexByte x =
    let s = "0123456789abcdef"
     in [s !! (x `div` 16), s !! (x `mod` 16)]
