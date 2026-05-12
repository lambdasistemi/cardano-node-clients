{-# LANGUAGE DataKinds #-}

module Cardano.Node.Client.TxBuildPublicApiSpec (spec) where

import Data.Map.Strict (Map)
import Data.Word (Word32)
import Test.Hspec

import Cardano.Node.Client.TxBuild

spec :: Spec
spec =
    describe "TxBuild public Conway API" $
        it "exports the Conway certificate and proposal surface" $ do
            _pubKeyCertWitness `seq` True `shouldBe` True
            _scriptCertWitness `seq` True `shouldBe` True
            _noProposalWitness `seq` True `shouldBe` True
            _guardrailProposalWitness `seq` True `shouldBe` True
            _alwaysAbstainDRep `shouldBe` DRepAlwaysAbstain

_certify ::
    ConwayTxCert ConwayEra ->
    CertWitness ->
    TxBuild q e Word32
_certify = certify

_registerAndVoteAbstain ::
    Credential Staking ->
    Coin ->
    CertWitness ->
    TxBuild q e Word32
_registerAndVoteAbstain = registerAndVoteAbstain

_propose ::
    ProposalProcedure ConwayEra ->
    ProposalWitness ->
    TxBuild q e Word32
_propose = propose

_proposeTreasuryWithdrawal ::
    Coin ->
    AccountAddress ->
    Anchor ->
    Map AccountAddress Coin ->
    StrictMaybe ScriptHash ->
    ProposalWitness ->
    TxBuild q e Word32
_proposeTreasuryWithdrawal = proposeTreasuryWithdrawal

_pubKeyCertWitness :: CertWitness
_pubKeyCertWitness = PubKeyCert

_scriptCertWitness :: CertWitness
_scriptCertWitness = ScriptCert (1 :: Integer)

_noProposalWitness :: ProposalWitness
_noProposalWitness = NoProposalScript

_guardrailProposalWitness :: ProposalWitness
_guardrailProposalWitness = GuardrailProposal (2 :: Integer)

_alwaysAbstainDRep :: DRep
_alwaysAbstainDRep = DRepAlwaysAbstain

_credential ::
    Credential Staking ->
    Credential Staking
_credential = id

_proposalProcedure ::
    ProposalProcedure ConwayEra ->
    ProposalProcedure ConwayEra
_proposalProcedure = id

_govAction ::
    GovAction ConwayEra ->
    GovAction ConwayEra
_govAction = id

_rewardAccount :: AccountAddress -> AccountAddress
_rewardAccount = id

_scriptHash :: ScriptHash -> ScriptHash
_scriptHash = id
