{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.ProviderSpec
Description : E2E tests for the N2C Provider
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.ProviderSpec (spec) where

import Control.Exception qualified as Exception
import Control.Monad (void)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word64, Word8)
import Lens.Micro ((^.))
import System.Timeout (timeout)
import Test.Hspec (
    Spec,
    around,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Cardano.Ledger.Address (AccountAddress)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.DRep (DRep)
import Cardano.Ledger.Keys (KeyRole (Staking))

import Cardano.Node.Client.Address (
    rewardAccountCredential,
 )
import Cardano.Node.Client.ConwayFixtures (
    mkRewardAccount,
    mkScriptRewardAccount,
 )
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
    withDevnet,
 )
import Cardano.Node.Client.N2C.Provider (
    mkN2CProvider,
 )
import Cardano.Node.Client.Provider (
    EpochNo (..),
    LedgerSnapshot (..),
    Provider (..),
    SlotNo (..),
    queryGovernanceStateH,
    queryLedgerSnapshotH,
    queryProtocolParamsH,
    queryRewardAccountsH,
    queryStakeRewardsH,
    queryTreasuryH,
    queryUTxOByTxInH,
    queryUTxOsAtH,
    queryVoteDelegateesH,
 )

spec :: Spec
spec =
    around withDevnet' $
        describe "Provider.N2C" $ do
            it "queryProtocolParams returns valid PParams" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    pp <-
                        expectWithin "queryProtocolParams" $
                            queryProtocolParams provider
                    let maxTxSize =
                            pp ^. ppMaxTxSizeL
                    maxTxSize
                        `shouldSatisfy` (> 0)

            it "queryUTxOs returns genesis funds" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    utxos <-
                        expectWithin "queryUTxOs" $
                            queryUTxOs
                                provider
                                genesisAddr
                    utxos
                        `shouldSatisfy` (not . null)

            it "queries ledger position through LSQ" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    snapshot <-
                        expectWithin "queryLedgerSnapshot" $
                            queryLedgerSnapshot provider
                    assertLedgerSnapshot snapshot

            it "queries treasury through LSQ" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    treasury <-
                        expectWithin "queryTreasury" $
                            queryTreasury provider
                    treasury
                        `shouldSatisfy` (>= Coin 0)

            it "queries governance state through LSQ" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    govState <-
                        expectWithin "queryGovernanceState" $
                            queryGovernanceState provider
                    void $ Exception.evaluate govState

            it "queries reward balances and vote delegatees through LSQ" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                        accounts =
                            sampleAccounts 11 12
                        credentials =
                            accountCredentials accounts
                    rewardBalances <-
                        expectWithin "queryRewardAccounts" $
                            queryRewardAccounts
                                provider
                                accounts
                    stakeRewards <-
                        expectWithin "queryStakeRewards" $
                            queryStakeRewards
                                provider
                                credentials
                    voteDelegatees <-
                        expectWithin "queryVoteDelegatees" $
                            queryVoteDelegatees
                                provider
                                credentials
                    assertRewardGroup
                        accounts
                        credentials
                        rewardBalances
                        stakeRewards
                        voteDelegatees

            it "groups UTxO queries in one acquired LSQ session" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                    (byAddr, byTxIn) <-
                        expectWithin "withAcquired UTxO group" $
                            withAcquired provider $ \handle -> do
                                utxosAt <-
                                    queryUTxOsAtH
                                        handle
                                        (Set.singleton genesisAddr)
                                let txIns =
                                        firstTxInsAt genesisAddr utxosAt
                                utxosByTxIn <-
                                    queryUTxOByTxInH
                                        handle
                                        txIns
                                pure (utxosAt, utxosByTxIn)
                    let addrUtxos =
                            Map.findWithDefault
                                []
                                genesisAddr
                                byAddr
                        txIns =
                            Set.fromList $
                                take 1 $
                                    fmap fst addrUtxos
                    addrUtxos
                        `shouldSatisfy` (not . null)
                    Map.keysSet byTxIn
                        `shouldBe` txIns

            it "groups ledger/account queries in one acquired LSQ session" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                        accounts =
                            sampleAccounts 21 22
                        credentials =
                            accountCredentials accounts
                    (snapshot, treasury, govState, rewards, votes) <-
                        expectWithin "withAcquired ledger/account group" $
                            withAcquired provider $ \handle -> do
                                ledgerSnapshot <-
                                    queryLedgerSnapshotH handle
                                treasuryValue <-
                                    queryTreasuryH handle
                                governanceState <-
                                    queryGovernanceStateH handle
                                rewardBalances <-
                                    queryRewardAccountsH
                                        handle
                                        accounts
                                voteDelegatees <-
                                    queryVoteDelegateesH
                                        handle
                                        credentials
                                pure
                                    ( ledgerSnapshot
                                    , treasuryValue
                                    , governanceState
                                    , rewardBalances
                                    , voteDelegatees
                                    )
                    assertLedgerSnapshot snapshot
                    treasury
                        `shouldSatisfy` (>= Coin 0)
                    void $ Exception.evaluate govState
                    Map.keysSet rewards
                        `shouldSatisfy` (`Set.isSubsetOf` accounts)
                    Map.keysSet votes
                        `shouldSatisfy` (`Set.isSubsetOf` credentials)

            it "combines devnet query families without cardano-cli" $
                \(lsq, _) -> do
                    let provider =
                            mkN2CProvider lsq
                        accounts =
                            sampleAccounts 31 32
                        credentials =
                            accountCredentials accounts
                    ( maxTxSize
                        , byAddr
                        , byTxIn
                        , snapshot
                        , treasury
                        , rewardBalances
                        , stakeRewards
                        , voteDelegatees
                        ) <-
                        expectWithin "withAcquired combined query group" $
                            withAcquired provider $ \handle -> do
                                pp <-
                                    queryProtocolParamsH handle
                                utxosAt <-
                                    queryUTxOsAtH
                                        handle
                                        (Set.singleton genesisAddr)
                                let txIns =
                                        firstTxInsAt genesisAddr utxosAt
                                utxosByTxIn <-
                                    queryUTxOByTxInH
                                        handle
                                        txIns
                                ledgerSnapshot <-
                                    queryLedgerSnapshotH handle
                                treasuryValue <-
                                    queryTreasuryH handle
                                rewards <-
                                    queryRewardAccountsH
                                        handle
                                        accounts
                                stakeRewardBalances <-
                                    queryStakeRewardsH
                                        handle
                                        credentials
                                votes <-
                                    queryVoteDelegateesH
                                        handle
                                        credentials
                                pure
                                    ( pp ^. ppMaxTxSizeL
                                    , utxosAt
                                    , utxosByTxIn
                                    , ledgerSnapshot
                                    , treasuryValue
                                    , rewards
                                    , stakeRewardBalances
                                    , votes
                                    )
                    let addrUtxos =
                            Map.findWithDefault
                                []
                                genesisAddr
                                byAddr
                        txIns =
                            Set.fromList $
                                take 1 $
                                    fmap fst addrUtxos
                    maxTxSize
                        `shouldSatisfy` (> 0)
                    addrUtxos
                        `shouldSatisfy` (not . null)
                    Map.keysSet byTxIn
                        `shouldBe` txIns
                    assertLedgerSnapshot snapshot
                    treasury
                        `shouldSatisfy` (>= Coin 0)
                    assertRewardGroup
                        accounts
                        credentials
                        rewardBalances
                        stakeRewards
                        voteDelegatees
  where
    withDevnet' action =
        withDevnet $ curry action

sampleAccounts :: Word8 -> Word8 -> Set.Set AccountAddress
sampleAccounts keyAccount scriptAccount =
    Set.fromList
        [ mkRewardAccount keyAccount
        , mkScriptRewardAccount scriptAccount
        ]

accountCredentials ::
    Set.Set AccountAddress ->
    Set.Set (Credential Staking)
accountCredentials =
    Set.map rewardAccountCredential

expectWithin :: String -> IO a -> IO a
expectWithin label action = do
    result <-
        timeout 30000000 action
    case result of
        Just value ->
            pure value
        Nothing ->
            expectationFailure message >> fail message
  where
    message =
        label <> " timed out after 30 seconds"

assertLedgerSnapshot :: LedgerSnapshot -> IO ()
assertLedgerSnapshot snapshot = do
    ledgerCurrentEra snapshot
        `shouldSatisfy` T.isInfixOf "Conway"
    slotNumber (ledgerTipSlot snapshot)
        `shouldSatisfy` (>= 0)
    epochNumber (ledgerEpoch snapshot)
        `shouldSatisfy` (>= 0)

assertRewardGroup ::
    Set.Set AccountAddress ->
    Set.Set (Credential Staking) ->
    Map.Map AccountAddress Coin ->
    Map.Map (Credential Staking) Coin ->
    Map.Map (Credential Staking) DRep ->
    IO ()
assertRewardGroup accounts credentials rewardBalances stakeRewards votes = do
    Map.keysSet rewardBalances
        `shouldSatisfy` (`Set.isSubsetOf` accounts)
    Map.keysSet stakeRewards
        `shouldSatisfy` (`Set.isSubsetOf` credentials)
    Map.keysSet votes
        `shouldSatisfy` (`Set.isSubsetOf` credentials)

firstTxInsAt ::
    (Ord addr, Ord txIn) =>
    addr ->
    Map.Map addr [(txIn, txOut)] ->
    Set.Set txIn
firstTxInsAt addr utxosAt =
    Set.fromList $
        take
            1
            ( fst
                <$> Map.findWithDefault
                    []
                    addr
                    utxosAt
            )

slotNumber :: SlotNo -> Word64
slotNumber (SlotNo slot) =
    slot

epochNumber :: EpochNo -> Word64
epochNumber (EpochNo epoch) =
    epoch
