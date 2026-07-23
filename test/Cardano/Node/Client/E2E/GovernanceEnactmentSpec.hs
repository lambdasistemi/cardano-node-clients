{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.E2E.GovernanceEnactmentSpec
Description : E2E test for stock-devnet governance enactment (issue 190)
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.GovernanceEnactmentSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Coerce (coerce)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Maybe.Strict (StrictMaybe (..))
import Data.OSet.Strict qualified as OSet
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
 )
import Cardano.Ledger.Alonzo.Scripts (ExUnits (..))
import Cardano.Ledger.Api (
    Anchor (..),
    AnchorData (..),
    GovAction (..),
    GovActionId (..),
    GovActionIx (..),
    ProposalProcedure (..),
    Vote (..),
    Voter (..),
    VotingProcedure (..),
    VotingProcedures (..),
    certsTxBodyL,
    coinTxOutL,
    emptyPParamsUpdate,
    feeTxBodyL,
    inputsTxBodyL,
    mkBasicTx,
    mkBasicTxBody,
    mkBasicTxOut,
    outputsTxBodyL,
    ppMaxTxExUnitsL,
    ppuMaxTxExUnitsL,
    proposalProceduresTxBodyL,
    txIdTx,
    txIdTxBody,
    votingProceduresTxBodyL,
 )
import Cardano.Ledger.BaseTypes (
    Network (..),
    TxIx (..),
    textToUrl,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.TxCert (
    ConwayDelegCert (..),
    ConwayGovCert (..),
    ConwayTxCert (..),
    Delegatee (..),
 )
import Cardano.Ledger.Core (hashAnnotated)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.DRep (DRep (..))
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject)

import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    ccColdKeyHash,
    ccColdSignKey,
    ccHotCredential,
    ccHotSignKey,
    genesisAddr,
    genesisSignKey,
    keyHashFromSignKey,
    withDevnet,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (
    Provider (..),
    queryProtocolParams,
    queryUTxOs,
 )
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter,
    submitTx,
 )

{- | The bumped @maxTxExUnits@ memory the test proposes and
expects to see enacted. Stock genesis value is 140000000.
@maxTxExUnits@ is in the network/no-stake-pool group, so a
@ParameterChange@ touching only it needs no SPO vote (unlike
@maxTxSize@, which is security-relevant).
-}
proposedMaxTxExUnitsMem :: Natural
proposedMaxTxExUnitsMem = 150_000_000

spec :: Spec
spec = describe "Governance enactment (stock devnet)" $ do
    it "enacts a voted ParameterChange on a fresh withDevnet devnet" $
        withDevnet $ \lsqCh ltxsCh -> do
            let provider = mkN2CProvider lsqCh
                submitter = mkN2CSubmitter ltxsCh

            pp0 <- queryProtocolParams provider
            let ExUnits stockMem _ = pp0 ^. ppMaxTxExUnitsL
            stockMem `shouldBe` 140_000_000

            proposeAndVote provider submitter
            waitForEnactment provider (90 :: Int)
  where
    waitForEnactment :: Provider IO -> Int -> IO ()
    waitForEnactment _ 0 =
        error
            "waitForEnactment: timed out waiting for \
            \maxTxExUnits ParameterChange enactment"
    waitForEnactment provider atts = do
        threadDelay 5_000_000
        ePP <- try @SomeException (queryProtocolParams provider)
        case ePP of
            Right pp -> do
                let ExUnits mem _ = pp ^. ppMaxTxExUnitsL
                putStrLn
                    ( "waitForEnactment poll ["
                        <> show atts
                        <> "]: maxTxExUnitsMem="
                        <> show mem
                    )
                if mem == proposedMaxTxExUnitsMem
                    then pure ()
                    else waitForEnactment provider (atts - 1)
            Left err -> do
                putStrLn ("waitForEnactment poll err: " <> show err)
                waitForEnactment provider (atts - 1)

{- | Register the genesis stake credential, register and
self-delegate a DRep, authorize the stock committee hot key,
propose a benign @maxTxExUnits@ bump, and cast DRep + CC yes
votes. Mirrors the shape issue #187 proved live.
-}
proposeAndVote ::
    Provider IO ->
    Submitter IO ->
    IO ()
proposeAndVote provider submitter = do
    let genesisKh = keyHashFromSignKey genesisSignKey
        khCred :: forall r. Credential r
        khCred = KeyHashObj (coerce genesisKh)
        ccColdCred :: Credential ColdCommitteeRole
        ccColdCred = KeyHashObj ccColdKeyHash
        ccHotCred :: Credential HotCommitteeRole
        ccHotCred = ccHotCredential
        -- The single stake pool registered in the stock
        -- shelley-genesis.json (@staking.pools@).
        stockPoolKh :: KeyHash StakePool
        stockPoolKh =
            KeyHash
                "e797e39f0782f92e18b2b46b30244d5d5887661149d5b44d36237c1a"

    utxos <- queryUTxOs provider genesisAddr
    case utxos of
        [] -> error "proposeAndVote: no UTxOs at genesisAddr"
        (initTxIn, initTxOut) : _ -> do
            let initCoin = initTxOut ^. coinTxOutL
                fee = Coin 10_000_000
                drepDeposit = Coin 500_000_000
                stakeDeposit = Coin 400_000

                stakeRegCert =
                    ConwayTxCertDeleg $
                        ConwayRegCert khCred (SJust stakeDeposit)
                drepCert =
                    ConwayTxCertGov $
                        ConwayRegDRep khCred drepDeposit SNothing
                delegCert =
                    ConwayTxCertDeleg $
                        ConwayDelegCert
                            khCred
                            (DelegStakeVote stockPoolKh (DRepCredential khCred))
                ccAuthCert =
                    ConwayTxCertGov $
                        ConwayAuthCommitteeHotKey ccColdCred ccHotCred

                change1Coin =
                    Coin
                        ( unCoin initCoin
                            - unCoin fee
                            - unCoin drepDeposit
                            - unCoin stakeDeposit
                        )
                txBody1 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton initTxIn
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut genesisAddr (inject change1Coin))
                        & feeTxBodyL .~ fee
                        & certsTxBodyL
                            .~ StrictSeq.fromList
                                [ stakeRegCert
                                , drepCert
                                , delegCert
                                , ccAuthCert
                                ]
                tx1 =
                    addKeyWitness genesisSignKey $
                        addKeyWitness ccColdSignKey $
                            mkBasicTx txBody1

            res1 <- submitTx submitter tx1
            case res1 of
                Submitted _ -> pure ()
                Rejected err ->
                    error $
                        "Tx 1 (registration + CC authorization) rejected: "
                            <> show err
            threadDelay 2_000_000

            -- Tx 2: propose the maxTxExUnits memory bump
            let ppu =
                    emptyPParamsUpdate @ConwayEra
                        & ppuMaxTxExUnitsL
                            .~ SJust (ExUnits proposedMaxTxExUnitsMem 10_000_000_000)
                propDeposit = Coin 50_000_000_000
                rewardAcnt = AccountAddress Testnet (AccountId khCred)
                dummyUrl =
                    fromMaybe (error "textToUrl failed") $
                        textToUrl 128 "https://example.com"
                dummyAnchor =
                    Anchor dummyUrl (hashAnnotated (AnchorData "dummy"))
                proposal =
                    ProposalProcedure
                        propDeposit
                        rewardAcnt
                        (ParameterChange SNothing ppu SNothing)
                        dummyAnchor
                tx2In = TxIn (txIdTx tx1) (TxIx 0)
                change2Coin =
                    Coin
                        ( unCoin change1Coin
                            - unCoin fee
                            - unCoin propDeposit
                        )
                txBody2 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton tx2In
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut genesisAddr (inject change2Coin))
                        & feeTxBodyL .~ fee
                        & proposalProceduresTxBodyL
                            .~ OSet.fromList [proposal]
                tx2 = addKeyWitness genesisSignKey (mkBasicTx txBody2)

            res2 <- submitTx submitter tx2
            case res2 of
                Submitted _ -> pure ()
                Rejected err ->
                    error $
                        "Tx 2 (proposal) rejected: " <> show err
            threadDelay 2_000_000

            -- Tx 3: DRep + CC yes votes
            let tx3In = TxIn (txIdTx tx2) (TxIx 0)
                change3Coin = Coin (unCoin change2Coin - unCoin fee)
                govId =
                    GovActionId (txIdTxBody txBody2) (GovActionIx 0)
                voterMap =
                    Map.fromList
                        [
                            ( DRepVoter khCred
                            , Map.fromList [(govId, voteYes)]
                            )
                        ,
                            ( CommitteeVoter ccHotCred
                            , Map.fromList [(govId, voteYes)]
                            )
                        ]
                voteYes = VotingProcedure VoteYes SNothing
                txBody3 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton tx3In
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut genesisAddr (inject change3Coin))
                        & feeTxBodyL .~ fee
                        & votingProceduresTxBodyL
                            .~ VotingProcedures voterMap
                tx3 =
                    addKeyWitness genesisSignKey $
                        addKeyWitness ccHotSignKey $
                            mkBasicTx txBody3

            res3 <- submitTx submitter tx3
            case res3 of
                Submitted _ -> pure ()
                Rejected err ->
                    error $
                        "Tx 3 (votes) rejected: " <> show err
