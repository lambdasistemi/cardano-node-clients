{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.Credentials
Description : Credential key-hash extraction helpers
License     : Apache-2.0

Helpers for reducing ledger credentials, addresses,
and governance voters to the key-hash bytes that
identify required key witnesses.
-}
module Cardano.Node.Client.Credentials (
    accountKeyHashBytes,
    addrPaymentKeyHashBytes,
    credentialKeyHashBytes,
    keyHashBytes,
    voterKeyHashBytes,
) where

import Data.ByteString qualified as BS

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
 )
import Cardano.Ledger.Conway.Governance (Voter (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (originalBytes)
import Cardano.Ledger.Keys (KeyHash (..))

addrPaymentKeyHashBytes :: Addr -> Maybe BS.ByteString
addrPaymentKeyHashBytes =
    \case
        Addr _ (KeyHashObj kh) _ ->
            Just (keyHashBytes kh)
        Addr _ (ScriptHashObj _) _ ->
            Nothing
        AddrBootstrap _ ->
            Nothing

accountKeyHashBytes :: AccountAddress -> Maybe BS.ByteString
accountKeyHashBytes =
    \case
        AccountAddress _ (AccountId (KeyHashObj kh)) ->
            Just (keyHashBytes kh)
        AccountAddress _ (AccountId (ScriptHashObj _)) ->
            Nothing

voterKeyHashBytes :: Voter -> Maybe BS.ByteString
voterKeyHashBytes =
    \case
        CommitteeVoter credential ->
            credentialKeyHashBytes credential
        DRepVoter credential ->
            credentialKeyHashBytes credential
        StakePoolVoter kh ->
            Just (keyHashBytes kh)

credentialKeyHashBytes :: Credential kd -> Maybe BS.ByteString
credentialKeyHashBytes =
    \case
        KeyHashObj kh ->
            Just (keyHashBytes kh)
        ScriptHashObj _ ->
            Nothing

keyHashBytes :: KeyHash kd -> BS.ByteString
keyHashBytes (KeyHash h) =
    originalBytes h
