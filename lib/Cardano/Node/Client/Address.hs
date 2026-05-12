{- |
Module      : Cardano.Node.Client.Address
Description : Typed address and credential helpers
License     : Apache-2.0

Small helpers for working with ledger address types without shelling
out to @cardano-cli address info@.
-}
module Cardano.Node.Client.Address (
    paymentCredentialFromAddr,
    stakeCredentialFromAddr,
    rewardAccountFromCredential,
    rewardAccountCredential,
    keyCredential,
    scriptCredential,
) where

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
 )
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Keys (KeyHash, KeyRole (Payment, Staking))

-- | Extract the payment credential from a Shelley-style address.
paymentCredentialFromAddr :: Addr -> Maybe (Credential Payment)
paymentCredentialFromAddr (Addr _network credential _stakeRef) =
    Just credential
paymentCredentialFromAddr (AddrBootstrap _) =
    Nothing

-- | Extract a base stake credential when an address carries one.
stakeCredentialFromAddr :: Addr -> Maybe (Credential Staking)
stakeCredentialFromAddr (Addr _network _payment (StakeRefBase credential)) =
    Just credential
stakeCredentialFromAddr _ =
    Nothing

-- | Build a reward account from a network and stake credential.
rewardAccountFromCredential ::
    Network ->
    Credential Staking ->
    AccountAddress
rewardAccountFromCredential network credential =
    AccountAddress
        network
        (AccountId credential)

-- | Extract the stake credential carried by a reward account.
rewardAccountCredential :: AccountAddress -> Credential Staking
rewardAccountCredential (AccountAddress _network (AccountId credential)) =
    credential

-- | Build a credential from a key hash.
keyCredential :: KeyHash kr -> Credential kr
keyCredential =
    KeyHashObj

-- | Build a credential from a script hash.
scriptCredential :: ScriptHash -> Credential kr
scriptCredential =
    ScriptHashObj
