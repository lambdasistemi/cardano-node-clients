{-# LANGUAGE DataKinds #-}

module Cardano.Node.Client.ConwayFixtures (
    mkHash28,
    mkStakeCredential,
    mkScriptStakeCredential,
    mkScriptHash,
    mkRewardAccount,
    mkScriptRewardAccount,
    mkCoin,
) where

import Cardano.Crypto.Hash (
    Hash,
    HashAlgorithm,
    hashFromBytes,
 )
import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
 )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Staking),
 )
import Data.ByteString qualified as BS
import Data.Maybe (fromJust)
import Data.Word (Word8)

mkHash28 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 27 0 ++ [n]

mkStakeCredential :: Word8 -> Credential Staking
mkStakeCredential n =
    KeyHashObj (KeyHash (mkHash28 n))

mkScriptStakeCredential :: Word8 -> Credential Staking
mkScriptStakeCredential n =
    ScriptHashObj (mkScriptHash n)

mkScriptHash :: Word8 -> ScriptHash
mkScriptHash n =
    ScriptHash (mkHash28 n)

mkRewardAccount :: Word8 -> AccountAddress
mkRewardAccount n =
    AccountAddress Testnet (AccountId (mkStakeCredential n))

mkScriptRewardAccount :: Word8 -> AccountAddress
mkScriptRewardAccount n =
    AccountAddress Testnet (AccountId (mkScriptStakeCredential n))

mkCoin :: Integer -> Coin
mkCoin = Coin
