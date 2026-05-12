{-# LANGUAGE DataKinds #-}

module Cardano.Node.Client.AddressSpec (spec) where

import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
 )

import Cardano.Crypto.Hash (
    Hash,
    HashAlgorithm,
    hashFromBytes,
 )
import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
 )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Payment, Staking),
 )
import Data.ByteString qualified as BS
import Data.Maybe (fromJust)
import Data.Word (Word8)

import Cardano.Node.Client.Address (
    keyCredential,
    paymentCredentialFromAddr,
    rewardAccountCredential,
    rewardAccountFromCredential,
    scriptCredential,
    stakeCredentialFromAddr,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.Address" $ do
        it "extracts payment and stake credentials from a base address" $ do
            let paymentCred =
                    mkPaymentCredential 1
                stakeCred =
                    mkStakeCredential 2
                addr =
                    Addr
                        Testnet
                        paymentCred
                        (StakeRefBase stakeCred)
            paymentCredentialFromAddr addr
                `shouldBe` Just paymentCred
            stakeCredentialFromAddr addr
                `shouldBe` Just stakeCred

        it "extracts payment credentials from enterprise addresses" $ do
            let paymentCred =
                    mkPaymentCredential 3
                addr =
                    Addr
                        Testnet
                        paymentCred
                        StakeRefNull
            paymentCredentialFromAddr addr
                `shouldBe` Just paymentCred
            stakeCredentialFromAddr addr
                `shouldBe` Nothing

        it "round-trips typed reward-account credentials" $ do
            let stakeCred =
                    mkStakeCredential 4
                rewardAccount =
                    rewardAccountFromCredential
                        Testnet
                        stakeCred
            rewardAccount
                `shouldBe` AccountAddress
                    Testnet
                    (AccountId stakeCred)
            rewardAccountCredential rewardAccount
                `shouldBe` stakeCred

        it "builds key and script credentials without CLI parsing" $ do
            let keyHash =
                    KeyHash (mkHash28 5)
                scriptHash =
                    ScriptHash (mkHash28 6)
            (keyCredential keyHash :: Credential Staking)
                `shouldBe` KeyHashObj keyHash
            (scriptCredential scriptHash :: Credential Staking)
                `shouldBe` ScriptHashObj scriptHash

mkPaymentCredential :: Word8 -> Credential Payment
mkPaymentCredential n =
    KeyHashObj (KeyHash (mkHash28 n))

mkStakeCredential :: Word8 -> Credential Staking
mkStakeCredential n =
    KeyHashObj (KeyHash (mkHash28 n))

mkHash28 ::
    (HashAlgorithm h) =>
    Word8 ->
    Hash h a
mkHash28 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 27 0 ++ [n]
