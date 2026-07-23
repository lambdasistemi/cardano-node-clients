{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.E2E.Governance
Description : On-chain governance bootstrapping for devnet PV11 transition
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.Governance (
    enactPV11Transition,
    assertPV11Enacted,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (SomeException, try)
import Control.Monad (forever, unless)
import Data.Aeson (Value (..), decodeFileStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Coerce (coerce)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Maybe.Strict (StrictMaybe (..))
import Data.OSet.Strict qualified as OSet
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import System.IO (hFlush, stdout)

import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
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
    ppCostModelsL,
    ppMaxTxExUnitsL,
    ppProtocolVersionL,
    ppuCostModelsL,
    ppuMaxTxExUnitsL,
    proposalProceduresTxBodyL,
    txIdTx,
    txIdTxBody,
    votingProceduresTxBodyL,
 )
import Cardano.Ledger.BaseTypes (
    Network (..),
    ProtVer (..),
    TxIx (..),
    boundRational,
    natVersion,
    textToUrl,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance ()
import Cardano.Ledger.Conway.TxCert (
    ConwayDelegCert (..),
    ConwayGovCert (..),
    ConwayTxCert (..),
    Delegatee (..),
 )
import Cardano.Ledger.Core (
    hashAnnotated,
    pattern RegPoolTxCert,
 )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.DRep (DRep (..))
import Cardano.Ledger.Hashes (VRFVerKeyHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (..),
    KeyRoleVRF (..),
 )
import Cardano.Ledger.Plutus (
    Language (PlutusV3),
    costModelsValid,
    getCostModelParams,
    mkCostModel,
    mkCostModels,
 )
import Cardano.Ledger.State (StakePoolParams (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Node.Client.E2E.Devnet (
    addKeyWitness,
    ccColdKeyHash,
    ccColdSignKey,
    ccHotCredential,
    ccHotSignKey,
    genesisAddr,
    genesisSignKey,
    harnessPoolColdSignKey,
    harnessPoolKh,
    keyHashFromSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Types (LSQChannel, LTxSChannel)
import Cardano.Node.Client.Provider (
    Provider (..),
    queryGovernanceState,
    queryProtocolParams,
    queryUTxOs,
 )
import Cardano.Node.Client.Submitter (SubmitResult (..), submitTx)

{- | Dummy VRF verification-key hash for the
runtime-registered harness pool. Distinct from the
stock genesis pool VRF; only uniqueness is required
for @RegPool@ (the pool does not forge blocks).
-}
harnessPoolVrfHash :: VRFVerKeyHash StakePoolVRF
harnessPoolVrfHash =
    VRFVerKeyHash
        "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00"

addKeyWitnesses :: [SignKeyDSIGN Ed25519DSIGN] -> ConwayTx -> ConwayTx
addKeyWitnesses sks tx = foldr addKeyWitness tx sks

{- | Submit governance transactions on devnet to transition from PV10 to PV11
and install the PlutusV3 cost models and max execution units from the fixture.
Blocks until the node reports major protocol version 11 and updated cost models.
-}
enactPV11Transition :: LSQChannel -> LTxSChannel -> IO ()
enactPV11Transition lsqCh ltxsCh = do
    putStrLn "enactPV11Transition: starting..."
    hFlush stdout

    let provider = mkN2CProvider lsqCh
        submitter = mkN2CSubmitter ltxsCh
        genesisKh = keyHashFromSignKey genesisSignKey
        khCred :: forall r. Credential r
        khCred = KeyHashObj (coerce genesisKh)
        ccColdCred :: Credential ColdCommitteeRole
        ccColdCred = KeyHashObj ccColdKeyHash
        ccHotCred :: Credential HotCommitteeRole
        ccHotCred = ccHotCredential

    -- 1. Query initial UTxO from genesis address
    putStrLn "enactPV11Transition: querying initial UTxOs from genesisAddr..."
    hFlush stdout
    utxos <- queryUTxOs provider genesisAddr
    putStrLn $ "enactPV11Transition: found " <> show (length utxos) <> " initial UTxOs."
    hFlush stdout

    case utxos of
        [] -> error "enactPV11Transition: no initial UTxOs found at genesisAddr"
        (initTxIn, initTxOut) : _ -> do
            let initCoin = initTxOut ^. coinTxOutL
                fee = Coin 10_000_000
                drepDeposit = Coin 500_000_000
                stakeDeposit = Coin 400_000
                -- Stock genesis @poolDeposit@ is 0.
                rewardAcnt = AccountAddress Testnet (AccountId khCred)

                stakeRegCert =
                    ConwayTxCertDeleg $
                        ConwayRegCert khCred (SJust stakeDeposit)

                drepCert =
                    ConwayTxCertGov $
                        ConwayRegDRep khCred drepDeposit SNothing

                -- Register a NEW harness-controlled pool on-chain (A-002).
                -- Stock genesis pool e797e39f… is left untouched; we do not
                -- rekey it and we do not lower SPO thresholds.
                poolParams =
                    StakePoolParams
                        { sppId = harnessPoolKh
                        , sppVrf = harnessPoolVrfHash
                        , sppPledge = Coin 0
                        , sppCost = Coin 0
                        , sppMargin =
                            fromMaybe (error "boundRational 0") $
                                boundRational 0
                        , sppAccountAddress = rewardAcnt
                        , sppOwners = Set.empty
                        , sppRelays = StrictSeq.empty
                        , sppMetadata = SNothing
                        }
                poolRegCert = RegPoolTxCert poolParams

                -- Delegate stake + DRep vote to the newly registered pool so
                -- it holds the genesis-funded active stake for SPO voting.
                delegCert =
                    ConwayTxCertDeleg $
                        ConwayDelegCert
                            khCred
                            (DelegStakeVote harnessPoolKh (DRepCredential khCred))

                ccAuthCert =
                    ConwayTxCertGov $
                        ConwayAuthCommitteeHotKey ccColdCred ccHotCred

                change1Coin = Coin (unCoin initCoin - unCoin fee - unCoin drepDeposit - unCoin stakeDeposit)

                txBody1 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton initTxIn
                        & outputsTxBodyL .~ StrictSeq.singleton (mkBasicTxOut genesisAddr (inject change1Coin))
                        & feeTxBodyL .~ fee
                        & certsTxBodyL
                            .~ StrictSeq.fromList
                                [ stakeRegCert
                                , drepCert
                                , poolRegCert
                                , delegCert
                                , ccAuthCert
                                ]

                -- Genesis key: stake/drep; CC cold: hot-key auth;
                -- harness pool cold: RegPool.
                tx1 =
                    addKeyWitnesses
                        [ genesisSignKey
                        , ccColdSignKey
                        , harnessPoolColdSignKey
                        ]
                        (mkBasicTx txBody1)

            putStrLn "enactPV11Transition: submitting Tx 1 (Registration)..."
            hFlush stdout
            res1 <- submitTx submitter tx1
            case res1 of
                Submitted _ -> putStrLn "enactPV11Transition: Tx 1 submitted successfully."
                Rejected err -> error $ "Tx 1 (Registration & Authorization) rejected: " <> show err
            hFlush stdout

            -- Wait 2 seconds for block inclusion
            threadDelay 2_000_000

            -- 2. Build and submit Tx 2: Governance Proposals
            fixture <- loadPV11Fixture
            let cmV3 = case mkCostModel PlutusV3 (pv11CostModel fixture) of
                    Right cm -> cm
                    Left err -> error $ "Failed to construct PlutusV3 CostModel: " <> show err
                costModels = mkCostModels (Map.singleton PlutusV3 cmV3)

                ppu =
                    emptyPParamsUpdate @ConwayEra
                        & ppuCostModelsL .~ SJust costModels
                        & ppuMaxTxExUnitsL .~ SJust (pv11MaxTxExUnits fixture)

                propDeposit = Coin 50_000_000_000
                dummyUrl = fromMaybe (error "textToUrl failed") $ textToUrl 128 "https://example.com"
                dummyAnchor = Anchor dummyUrl (hashAnnotated (AnchorData "dummy"))

                prop1 = ProposalProcedure propDeposit rewardAcnt (HardForkInitiation SNothing (ProtVer (natVersion @11) 0)) dummyAnchor
                prop2 = ProposalProcedure propDeposit rewardAcnt (ParameterChange SNothing ppu SNothing) dummyAnchor

                tx2In = TxIn (txIdTx tx1) (TxIx 0)
                change2Coin = Coin (unCoin change1Coin - unCoin fee - 2 * unCoin propDeposit)

                txBody2 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton tx2In
                        & outputsTxBodyL .~ StrictSeq.singleton (mkBasicTxOut genesisAddr (inject change2Coin))
                        & feeTxBodyL .~ fee
                        & proposalProceduresTxBodyL .~ OSet.fromList [prop1, prop2]

                tx2 = addKeyWitnesses [genesisSignKey] (mkBasicTx txBody2)

            putStrLn "enactPV11Transition: submitting Tx 2 (Proposals)..."
            hFlush stdout
            res2 <- submitTx submitter tx2
            case res2 of
                Submitted _ -> putStrLn "enactPV11Transition: Tx 2 submitted successfully."
                Rejected err -> error $ "Tx 2 (Proposals) rejected: " <> show err
            hFlush stdout

            -- Wait 2 seconds for proposal block inclusion
            threadDelay 2_000_000

            -- 3. Build and submit Tx 3: Governance Votes (DRep + CC + SPO).
            -- SPO Yes is cast by the runtime-registered harness pool
            -- (harnessPoolKh), not stock e797e39f… which has no cold key.
            let tx3In = TxIn (txIdTx tx2) (TxIx 0)
                change3Coin = Coin (unCoin change2Coin - unCoin fee)
                tx2Id = txIdTxBody txBody2
                govId1 = GovActionId tx2Id (GovActionIx 0)
                govId2 = GovActionId tx2Id (GovActionIx 1)

                drepVoter = DRepVoter khCred
                ccVoter = CommitteeVoter ccHotCred
                spoVoter = StakePoolVoter harnessPoolKh
                voteYes = VotingProcedure VoteYes SNothing

                voterMap =
                    Map.fromList
                        [ (drepVoter, Map.fromList [(govId1, voteYes), (govId2, voteYes)])
                        , (ccVoter, Map.fromList [(govId1, voteYes), (govId2, voteYes)])
                        , (spoVoter, Map.fromList [(govId1, voteYes)])
                        ]
                votingProcedures = VotingProcedures voterMap

                txBody3 =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton tx3In
                        & outputsTxBodyL .~ StrictSeq.singleton (mkBasicTxOut genesisAddr (inject change3Coin))
                        & feeTxBodyL .~ fee
                        & votingProceduresTxBodyL .~ votingProcedures

                -- Hot CC: committee vote; harness pool cold: SPO vote.
                tx3 =
                    addKeyWitnesses
                        [ genesisSignKey
                        , ccHotSignKey
                        , harnessPoolColdSignKey
                        ]
                        (mkBasicTx txBody3)

            putStrLn "enactPV11Transition: submitting Tx 3 (Votes)..."
            hFlush stdout
            res3 <- submitTx submitter tx3
            case res3 of
                Submitted _ -> putStrLn "enactPV11Transition: Tx 3 submitted successfully."
                Rejected err -> error $ "Tx 3 (Votes) rejected: " <> show err
            hFlush stdout

            -- 4. Poll until PV11 and 350 PlutusV3 cost models are enacted
            putStrLn "enactPV11Transition: entering waitForPV11..."
            hFlush stdout
            waitForPV11 provider 90

data PV11Fixture = PV11Fixture
    { pv11CostModel :: [Int64]
    , pv11MaxTxExUnits :: ExUnits
    }

loadPV11Fixture :: IO PV11Fixture
loadPV11Fixture = do
    mVal <- decodeFileStrict "e2e-test/fixtures/pparams-pv11-mainnet.json"
    case mVal of
        Just (Object top) -> do
            cmList <- case KM.lookup "costModels" top of
                Just (Object cms) -> case KM.lookup "PlutusV3" cms of
                    Just (Array arr) -> do
                        let parseNum (Number n) = floor n
                            parseNum _ = error "Invalid number in PlutusV3 cost model"
                        pure $ map parseNum (foldr (:) [] arr)
                    _ -> error "PlutusV3 key missing in costModels fixture"
                _ -> error "costModels key missing in fixture"
            exUnits <- case KM.lookup "maxTxExecutionUnits" top of
                Just (Object ex) -> do
                    let getNum k = case KM.lookup k ex of
                            Just (Number n) -> floor n
                            _ -> error $ "Missing/invalid " <> show k <> " in maxTxExecutionUnits fixture"
                    pure $ ExUnits (getNum "memory") (getNum "steps")
                _ -> error "maxTxExecutionUnits key missing in fixture"
            pure $ PV11Fixture cmList exUnits
        _ -> error "Failed to parse pparams-pv11-mainnet.json fixture"

waitForPV11 :: Provider IO -> Int -> IO ()
waitForPV11 provider attempts =
    withAsync (forever $ threadDelay 1_000_000) $ \_ -> do
        putStrLn "waitForPV11: starting continuous poll loop with RTS heartbeat..."
        hFlush stdout
        pollLoop attempts
  where
    pollLoop :: Int -> IO ()
    pollLoop 0 = error "waitForPV11: timed out waiting for PV11 enactment"
    pollLoop atts = do
        threadDelay 3_000_000
        eGS <- try @SomeException (queryGovernanceState provider)
        case eGS of
            Right gs -> putStrLn ("waitForPV11 GovState: " <> show gs)
            Left err -> putStrLn ("waitForPV11 GovState err: " <> show err)
        hFlush stdout
        ePP <- try @SomeException (queryProtocolParams provider)
        case ePP of
            Right pp -> do
                let ProtVer major _ = pp ^. ppProtocolVersionL
                    cms = pp ^. ppCostModelsL
                    v3Len = case Map.lookup PlutusV3 (costModelsValid cms) of
                        Just cm -> length (getCostModelParams cm)
                        Nothing -> 0
                    exMax = pp ^. ppMaxTxExUnitsL
                putStrLn $ "waitForPV11 poll [" <> show (attempts - atts + 1) <> "]: major=" <> show major <> " v3Len=" <> show v3Len <> " exMax=" <> show exMax
                hFlush stdout
                if major >= natVersion @11 && v3Len == 350 && exMax == ExUnits 16_500_000 10_000_000_000
                    then pure ()
                    else pollLoop (atts - 1)
            Left err -> do
                putStrLn $ "waitForPV11 poll error [" <> show (attempts - atts + 1) <> "]: " <> show err
                hFlush stdout
                pollLoop (atts - 1)

{- | Assert that protocol version 11 and 350 PlutusV3 cost models are currently enacted.
Queries protocol parameters once. Throws an error naming the condition that failed if not.
-}
assertPV11Enacted :: Provider IO -> IO ()
assertPV11Enacted provider = do
    pp <- queryProtocolParams provider
    let ProtVer major _minor = pp ^. ppProtocolVersionL
        cms = pp ^. ppCostModelsL
        v3Len = case Map.lookup PlutusV3 (costModelsValid cms) of
            Just cm -> length (getCostModelParams cm)
            Nothing -> 0
    unless (major == natVersion @11) $
        error $
            "assertPV11Enacted: expected major protocol version 11, got " <> show major
    unless (v3Len == 350) $
        error $
            "assertPV11Enacted: expected 350 PlutusV3 cost model parameters, got " <> show v3Len
