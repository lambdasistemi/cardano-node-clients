{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.ProviderSpec
Description : E2E tests for the N2C Provider
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.ProviderSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception qualified as Exception
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64, Word8)
import Lens.Micro ((&), (.~), (^.))
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    getPermissions,
    listDirectory,
    setOwnerWritable,
    setPermissions,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
import Cardano.Ledger.Allegra (AllegraEra)
import Cardano.Ledger.Api (
    inputsTxBodyL,
    mkBasicTx,
    mkBasicTxBody,
 )
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.BaseTypes (Globals (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.DRep (DRep)
import Cardano.Ledger.Genesis (NoGenesis (..))
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.Shelley.Genesis (
    ShelleyGenesis,
    mkShelleyGlobals,
 )
import Cardano.Slotting.EpochInfo.API (
    EpochInfo (..),
    epochInfoEpoch,
    epochInfoFirst,
    epochInfoSize,
    epochInfoSlotLength,
    epochInfoSlotToRelativeTime,
 )
import Cardano.Slotting.Slot (EpochSize (..))
import Cardano.Slotting.Time (
    RelativeTime (..),
    SlotLength,
    SystemStart (..),
    getSlotLength,
    mkSlotLength,
    toRelativeTime,
 )

import Ouroboros.Consensus.Cardano.Block (
    CardanoEras,
    StandardCrypto,
    pattern QueryIfCurrentConway,
 )
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query (
    QueryHardFork (GetInterpreter),
    pattern QueryHardFork,
 )
import Ouroboros.Consensus.HardFork.History.EpochInfo (
    interpreterToEpochInfo,
 )
import Ouroboros.Consensus.HardFork.History.Qry (
    Interpreter,
    Qry,
    epochToSize,
    epochToSlot',
    interpretQuery,
    slotToEpoch',
    slotToSlotLength,
    slotToWallclock,
 )
import Ouroboros.Consensus.Ledger.Query (
    Query (BlockQuery, GetSystemStart),
 )
import Ouroboros.Consensus.Shelley.Ledger.Config (
    getCompactGenesis,
 )
import Ouroboros.Consensus.Shelley.Ledger.Ledger (
    ShelleyLedgerConfig (shelleyLedgerGlobals),
    mkShelleyLedgerConfig,
 )
import Ouroboros.Consensus.Shelley.Ledger.Query (
    pattern GetGenesisConfig,
 )

import Cardano.Node.Client.Address (
    rewardAccountCredential,
 )
import Cardano.Node.Client.ConwayFixtures (
    mkRewardAccount,
    mkScriptRewardAccount,
 )
import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
    genesisDir,
    withDevnet,
    withDevnetFromGenesis,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (
    queryAcquiredLSQ,
    withAcquiredLSQ,
 )
import Cardano.Node.Client.N2C.Provider (
    mkN2CProvider,
    withAcquiredN2CProviderAndGlobals,
 )
import Cardano.Node.Client.N2C.Types (LSQChannel)
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
import Cardano.Node.Client.Validity (ValidityChoice (AutoLongest))

spec :: Spec
spec = do
    -- The devnet launcher prepares a single fixed temporary
    -- directory, so a devnet started from a modified genesis
    -- cannot be nested inside the shared bracket. The
    -- era-mismatch and bounded-offline examples therefore live
    -- outside it, in 'ownDevnetSpec'.
    sharedDevnetSpec
    ownDevnetSpec

sharedDevnetSpec :: Spec
sharedDevnetSpec =
    around withDevnet' $
        describe "Provider.N2C" $ do
            it "acquires real Globals and provider in one LSQ snapshot" $
                \(lsq, _) -> do
                    (rawGenesis, rawStart, rawInterpreter) <-
                        expectWithin "independent raw acquisition" $
                            independentRawSnapshot lsq
                    let expectedGlobals =
                            mkShelleyGlobals
                                rawGenesis
                                (independentEpochInfo rawInterpreter)
                        canonicalGlobals =
                            canonicalGlobalsFrom
                                rawGenesis
                                rawInterpreter
                    expectWithin "withAcquiredN2CProviderAndGlobals" $
                        withAcquiredN2CProviderAndGlobals lsq $
                            \globals provider -> do
                                assertGlobalsScalars
                                    globals
                                    expectedGlobals
                                assertGlobalsScalars
                                    globals
                                    canonicalGlobals
                                systemStart globals
                                    `shouldBe` rawStart
                                snapshot <-
                                    queryLedgerSnapshot provider
                                assertEpochInfoAgrees
                                    (epochInfo globals)
                                    (epochInfo expectedGlobals)
                                    (ledgerTipSlot snapshot)
                                assertDevnetCoordinate
                                    globals
                                    snapshot
                                assertSnapshotProvider provider

            it "keeps Globals and provider stable for the acquired callback lifetime" $
                \(lsq, _) ->
                    expectWithin "acquired callback lifetime" $
                        withAcquiredN2CProviderAndGlobals lsq $
                            \globals provider -> do
                                (firstEra, utxosAt) <-
                                    withAcquired provider $ \handle -> do
                                        ledger <-
                                            queryLedgerSnapshotH handle
                                        utxos <-
                                            queryUTxOsAtH
                                                handle
                                                (Set.singleton genesisAddr)
                                        pure (ledgerCurrentEra ledger, utxos)
                                (maxTxSize, treasury) <-
                                    withAcquired provider $ \handle -> do
                                        pp <-
                                            queryProtocolParamsH handle
                                        treasuryValue <-
                                            queryTreasuryH handle
                                        pure
                                            ( pp ^. ppMaxTxSizeL
                                            , treasuryValue
                                            )
                                snapshot <-
                                    queryLedgerSnapshot provider
                                firstEra
                                    `shouldSatisfy` T.isInfixOf "Conway"
                                ledgerCurrentEra snapshot
                                    `shouldBe` firstEra
                                Map.findWithDefault
                                    []
                                    genesisAddr
                                    utxosAt
                                    `shouldSatisfy` (not . null)
                                maxTxSize
                                    `shouldSatisfy` (> 0)
                                treasury
                                    `shouldSatisfy` (>= Coin 0)
                                -- The one callback 'Globals' is still the
                                -- coordinate source after several handle
                                -- groups; no replacement value was needed.
                                assertDevnetCoordinate globals snapshot
                                assertSnapshotProvider provider

            it "does not infer system start from current time or a reconstructed timestamp" $
                \(lsq, _) -> do
                    (_, rawStart, _) <-
                        expectWithin "independent raw acquisition" $
                            independentRawSnapshot lsq
                    firstStart <-
                        expectWithin "first acquisition" $
                            withAcquiredN2CProviderAndGlobals lsq $
                                \globals _provider ->
                                    pure (systemStart globals)
                    threadDelay 2000000
                    secondStart <-
                        expectWithin "second acquisition" $
                            withAcquiredN2CProviderAndGlobals lsq $
                                \globals _provider ->
                                    pure (systemStart globals)
                    firstStart `shouldBe` rawStart
                    secondStart `shouldBe` rawStart
                    firstStart `shouldBe` secondStart
                    firstStart
                        `shouldSatisfy` (/= posixEpochStart)
                    firstStart
                        `shouldSatisfy` (/= forbiddenReconstructedStart)
                    secondStart
                        `shouldSatisfy` (/= forbiddenReconstructedStart)
                    fixture <- syntheticDevnetGlobalsFixture
                    systemStart fixture
                        `shouldBe` syntheticSystemStart
                            syntheticDevnetCoordinate
                    implementationSource <-
                        BS.readFile
                            "lib/Cardano/Node/Client/N2C/Provider.hs"
                    assertNoClockProvenance implementationSource

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

{- | Examples that must not share the devnet bracket: one starts
its own pre-Conway devnet, the other is entirely offline.
-}
ownDevnetSpec :: Spec
ownDevnetSpec =
    describe "Provider.N2C acquisition provenance" $ do
        it "exposes current-era and interpreter horizon failures" $ do
            fixture <- syntheticDevnetGlobalsFixture
            epochInfoSlotToRelativeTime
                (epochInfo fixture)
                (SlotNo 200)
                `shouldSatisfy` isHorizonFailure
            sourceDir <- genesisDir
            withSystemTempDirectory "pre-conway-genesis" $ \tmpDir -> do
                let genesisCopy = tmpDir </> "genesis"
                copyGenesisTree sourceDir genesisCopy
                delayConwayHardFork genesisCopy
                outcome <-
                    expectWithin "pre-Conway acquisition" $
                        withDevnetFromGenesis genesisCopy $
                            \lsq _ ->
                                Exception.try @Exception.ErrorCall $
                                    withAcquiredN2CProviderAndGlobals
                                        lsq
                                        ( \globals _provider ->
                                            void $
                                                Exception.evaluate
                                                    (systemStart globals)
                                        )
                eraMismatchReported outcome
                    `shouldBe` True

        it "uses one explicitly synthetic coordinate in bounded offline checks" $ do
            fixture <- syntheticDevnetGlobalsFixture
            let coordinate = syntheticDevnetCoordinate
                offline = syntheticOfflineProvider coordinate
            assertSyntheticCoordinateIdentity coordinate fixture offline
            -- The one fixture 'Globals' reaches both the mock
            -- builder and the mock guard through one callback.
            (builderGlobals, guardGlobals) <-
                withSyntheticSnapshot fixture offline $
                    \globals provider -> do
                        built <-
                            mockBuilderStep globals provider
                        guarded <-
                            mockGuardStep globals
                        pure (built, guarded)
            assertGlobalsScalars builderGlobals guardGlobals
            assertGlobalsScalars builderGlobals fixture

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

{- | Query compact genesis, system start, and the hard-fork
interpreter through a test-owned acquisition, independent of
the provider under test.
-}
independentRawSnapshot ::
    LSQChannel ->
    IO
        ( ShelleyGenesis
        , SystemStart
        , Interpreter (CardanoEras StandardCrypto)
        )
independentRawSnapshot lsq =
    withAcquiredLSQ lsq $ \acquired -> do
        genesisResult <-
            queryAcquiredLSQ acquired $
                BlockQuery $
                    QueryIfCurrentConway GetGenesisConfig
        compactGenesis <-
            case genesisResult of
                Right value ->
                    pure value
                Left _mismatch ->
                    fail
                        "independent genesis query: node not in Conway"
        start <-
            queryAcquiredLSQ acquired GetSystemStart
        interpreter <-
            queryAcquiredLSQ acquired $
                BlockQuery $
                    QueryHardFork GetInterpreter
        pure
            ( getCompactGenesis compactGenesis
            , start
            , interpreter
            )

{- | Build an 'EpochInfo' straight from the queried interpreter,
without the consensus ledger-config path the implementation uses.
-}
independentEpochInfo ::
    Interpreter xs ->
    EpochInfo (Either T.Text)
independentEpochInfo interpreter =
    EpochInfo
        { epochInfoSize_ = runQry . epochToSize
        , epochInfoFirst_ = runQry . epochToSlot'
        , epochInfoEpoch_ = \slot ->
            fst <$> runQry (slotToEpoch' slot)
        , epochInfoSlotToRelativeTime_ = \slot ->
            fst <$> runQry (slotToWallclock slot)
        , epochInfoSlotLength_ = runQry . slotToSlotLength
        }
  where
    runQry :: Qry a -> Either T.Text a
    runQry =
        first (T.pack . show)
            . interpretQuery interpreter

{- | Construct 'Globals' through the pinned consensus canonical
path, from independently queried values.
-}
canonicalGlobalsFrom ::
    ShelleyGenesis ->
    Interpreter (CardanoEras StandardCrypto) ->
    Globals
canonicalGlobalsFrom genesis interpreter =
    shelleyLedgerGlobals ledgerConfig
  where
    ledgerConfig :: ShelleyLedgerConfig AllegraEra
    ledgerConfig =
        mkShelleyLedgerConfig
            genesis
            NoGenesis
            (interpreterToEpochInfo interpreter)

-- | Compare the ten scalar 'Globals' fields.
assertGlobalsScalars :: Globals -> Globals -> IO ()
assertGlobalsScalars observed expected = do
    slotsPerKESPeriod observed
        `shouldBe` slotsPerKESPeriod expected
    stabilityWindow observed
        `shouldBe` stabilityWindow expected
    randomnessStabilisationWindow observed
        `shouldBe` randomnessStabilisationWindow expected
    securityParameter observed
        `shouldBe` securityParameter expected
    maxKESEvo observed
        `shouldBe` maxKESEvo expected
    quorum observed
        `shouldBe` quorum expected
    maxLovelaceSupply observed
        `shouldBe` maxLovelaceSupply expected
    activeSlotCoeff observed
        `shouldBe` activeSlotCoeff expected
    networkId observed
        `shouldBe` networkId expected
    systemStart observed
        `shouldBe` systemStart expected

{- | Compare the eleventh field behaviourally: 'EpochInfo' is a
record of functions and has no 'Eq' instance.
-}
assertEpochInfoAgrees ::
    EpochInfo (Either T.Text) ->
    EpochInfo (Either T.Text) ->
    SlotNo ->
    IO ()
assertEpochInfoAgrees observed expected tipSlot = do
    mapM_ compareSlot [SlotNo 0, SlotNo 1, tipSlot]
    mapM_ compareEpoch [EpochNo 0, EpochNo 1]
    -- Whether the devnet tip has already passed epoch 1 depends on
    -- timing, so the paired-failure branch above is not guaranteed
    -- to be exercised by it. This query is past any interpreter
    -- horizon the node can hold, so both real paths must expose a
    -- 'PastHorizon' failure on every run.
    compareSlot farBeyondHorizon
    compareEpoch farBeyondHorizonEpoch
    epochInfoEpoch observed farBeyondHorizon
        `shouldSatisfy` isPastHorizonFailure
    epochInfoSize observed farBeyondHorizonEpoch
        `shouldSatisfy` isPastHorizonFailure
  where
    farBeyondHorizon = SlotNo 1000000000
    farBeyondHorizonEpoch = EpochNo 1000000
    isPastHorizonFailure :: forall a. Either T.Text a -> Bool
    isPastHorizonFailure (Left message) = isPastHorizon message
    isPastHorizonFailure _ = False
    -- Successful results must agree exactly. A past-horizon
    -- payload embeds the call stack of whichever construction
    -- raised it, so paired failures are compared on the pinned
    -- 'PastHorizon' constructor marker only — the differing
    -- call-stack detail is ignored, but the failure class is
    -- still proven, and a mixed success/failure pair fails.
    sameOutcome ::
        forall a.
        (Eq a, Show a) =>
        Either T.Text a ->
        Either T.Text a ->
        IO ()
    sameOutcome observedResult expectedResult =
        case (observedResult, expectedResult) of
            (Right observedValue, Right expectedValue) ->
                observedValue `shouldBe` expectedValue
            (Left observedError, Left expectedError) -> do
                isPastHorizon observedError
                    `shouldBe` True
                isPastHorizon expectedError
                    `shouldBe` True
            (Left observedError, Right expectedValue) ->
                expectationFailure $
                    "callback EpochInfo failed where the independent \
                    \EpochInfo returned "
                        <> show expectedValue
                        <> ": "
                        <> T.unpack observedError
            (Right observedValue, Left expectedError) ->
                expectationFailure $
                    "callback EpochInfo returned "
                        <> show observedValue
                        <> " where the independent EpochInfo failed: "
                        <> T.unpack expectedError
    isPastHorizon = T.isInfixOf "PastHorizon"
    compareSlot slot = do
        sameOutcome
            (epochInfoEpoch observed slot)
            (epochInfoEpoch expected slot)
        sameOutcome
            (epochInfoSlotToRelativeTime observed slot)
            (epochInfoSlotToRelativeTime expected slot)
        sameOutcome
            (getSlotLength <$> epochInfoSlotLength observed slot)
            (getSlotLength <$> epochInfoSlotLength expected slot)
    compareEpoch epoch = do
        sameOutcome
            (epochInfoSize observed epoch)
            (epochInfoSize expected epoch)
        sameOutcome
            (epochInfoFirst observed epoch)
            (epochInfoFirst expected epoch)

{- | Derive the devnet coordinate from the acquired 'Globals' and
the acquired provider rather than from literals in the
implementation.
-}
assertDevnetCoordinate :: Globals -> LedgerSnapshot -> IO ()
assertDevnetCoordinate globals snapshot = do
    epochInfoSize (epochInfo globals) (EpochNo 0)
        `shouldBe` Right (EpochSize 100)
    (getSlotLength <$> epochInfoSlotLength (epochInfo globals) (SlotNo 0))
        `shouldBe` Right 0.1
    epochInfoFirst (epochInfo globals) (EpochNo 0)
        `shouldBe` Right (SlotNo 0)
    epochInfoEpoch (epochInfo globals) (SlotNo 0)
        `shouldBe` Right (EpochNo 0)
    ledgerCurrentEra snapshot
        `shouldSatisfy` T.isInfixOf "Conway"

{- | Exercise tip, parameters, UTxO, time conversion, upper-bound
selection, and evaluation through the supplied snapshot provider.
-}
assertSnapshotProvider :: Provider IO -> IO ()
assertSnapshotProvider provider = do
    pp <- queryProtocolParams provider
    (pp ^. ppMaxTxSizeL)
        `shouldSatisfy` (> 0)
    utxos <- queryUTxOs provider genesisAddr
    utxos
        `shouldSatisfy` (not . null)
    floorSlot <- posixMsToSlot provider 0
    ceilSlot <- posixMsCeilSlot provider 0
    floorSlot `shouldBe` SlotNo 0
    ceilSlot `shouldBe` SlotNo 0
    upperBound <- queryUpperBoundSlot provider AutoLongest
    isRightSlot upperBound `shouldBe` True
    evaluation <-
        evaluateTx provider $
            mkBasicTx $
                mkBasicTxBody
                    & inputsTxBodyL
                        .~ Set.fromList (take 1 (fst <$> utxos))
    Map.size evaluation `shouldBe` 0
  where
    isRightSlot =
        either (const False) (const True)

{- | Explicitly synthetic, test-only devnet coordinate. It is
never exported by the library, never supplied to the live
callback, and authoritative only for the bounded interval it
names.
-}
data SyntheticDevnetCoordinate = SyntheticDevnetCoordinate
    { syntheticSystemStart :: SystemStart
    , syntheticSlotLength :: SlotLength
    , syntheticEpochLength :: EpochSize
    , syntheticConwayStart :: EpochNo
    , syntheticHorizon :: SlotNo
    }

-- | Deterministic, non-POSIX-epoch-zero synthetic source record.
syntheticDevnetCoordinate :: SyntheticDevnetCoordinate
syntheticDevnetCoordinate =
    SyntheticDevnetCoordinate
        { syntheticSystemStart =
            systemStartFromText syntheticStartText
        , syntheticSlotLength = mkSlotLength 0.1
        , syntheticEpochLength = EpochSize 100
        , syntheticConwayStart = EpochNo 0
        , syntheticHorizon = SlotNo 199
        }

-- | The named deterministic synthetic start.
syntheticStartText :: T.Text
syntheticStartText = "2030-01-01T00:00:00Z"

-- | POSIX epoch zero, used only as a forbidden-value witness.
posixEpochStart :: SystemStart
posixEpochStart =
    systemStartFromText "1970-01-01T00:00:00Z"

{- | The A-064 reconstructed timestamp. It is a forbidden
provenance source and appears here only as a witness the live
value must differ from.
-}
forbiddenReconstructedStart :: SystemStart
forbiddenReconstructedStart =
    systemStartFromText "2026-07-26T10:59:39Z"

{- | Decode an ISO-8601 instant with Aeson, so the fixture
obtains typed time values without a direct @time@ dependency.
-}
systemStartFromText :: T.Text -> SystemStart
systemStartFromText text =
    case Aeson.eitherDecodeStrict encoded of
        Right value -> SystemStart value
        Left err ->
            error $
                "systemStartFromText: " <> err
  where
    encoded =
        TE.encodeUtf8 $
            "\"" <> text <> "\""

{- | The one bounded synthetic fixture of this repository. It
reads the pinned devnet Shelley genesis and replaces only its
@systemStart@ placeholder with the deterministic synthetic
start before decoding, then applies the canonical ledger
constructor. It is defined here and never exported by the
library.
-}
syntheticDevnetGlobalsFixture :: IO Globals
syntheticDevnetGlobalsFixture = do
    dir <- genesisDir
    raw <-
        BS.readFile (dir </> "shelley-genesis.json")
    let patched =
            TE.encodeUtf8 $
                T.replace
                    "PLACEHOLDER"
                    syntheticStartText
                    (TE.decodeUtf8 raw)
    case Aeson.eitherDecodeStrict patched of
        Right genesis ->
            pure $
                mkShelleyGlobals
                    genesis
                    ( syntheticEpochInfo
                        syntheticDevnetCoordinate
                    )
        Left err ->
            error $
                "syntheticDevnetGlobalsFixture: " <> err

{- | Bounded 'EpochInfo' derived from the synthetic source
record. Slots past the named horizon fail; nothing is
extrapolated and no safe zone is extended.
-}
syntheticEpochInfo ::
    SyntheticDevnetCoordinate ->
    EpochInfo (Either T.Text)
syntheticEpochInfo coordinate =
    EpochInfo
        { epochInfoSize_ = \epoch ->
            withinEpochHorizon epoch $
                syntheticEpochLength coordinate
        , epochInfoFirst_ = \epoch ->
            withinEpochHorizon epoch $
                SlotNo (unEpochNo epoch * epochLength)
        , epochInfoEpoch_ = \slot ->
            withinHorizon slot $
                EpochNo (unSlotNo slot `div` epochLength)
        , epochInfoSlotToRelativeTime_ = \slot ->
            withinHorizon slot $
                RelativeTime $
                    fromIntegral (unSlotNo slot) * slotSeconds
        , epochInfoSlotLength_ = \slot ->
            withinHorizon slot $
                syntheticSlotLength coordinate
        }
  where
    epochLength =
        unEpochSize (syntheticEpochLength coordinate)
    slotSeconds =
        getSlotLength (syntheticSlotLength coordinate)
    horizon =
        unSlotNo (syntheticHorizon coordinate)
    withinHorizon :: forall a. SlotNo -> a -> Either T.Text a
    withinHorizon slot value
        | unSlotNo slot <= horizon = Right value
        | otherwise =
            Left $
                "synthetic devnet fixture: slot "
                    <> T.pack (show (unSlotNo slot))
                    <> " is past the bounded horizon"
    withinEpochHorizon :: forall a. EpochNo -> a -> Either T.Text a
    withinEpochHorizon epoch value
        | unEpochNo epoch * epochLength <= horizon =
            Right value
        | otherwise =
            Left $
                "synthetic devnet fixture: epoch "
                    <> T.pack (show (unEpochNo epoch))
                    <> " is past the bounded horizon"

{- | Offline provider whose POSIX/slot conversion is derived
from the same synthetic source record, by arithmetic
independent of the fixture 'EpochInfo'. It shares that
fixture's bounded coordinate: a candidate slot past
'syntheticHorizon' fails with the named marker instead of
being extrapolated. Every other operation fails loudly rather
than returning fabricated ledger data.
-}
syntheticOfflineProvider ::
    SyntheticDevnetCoordinate ->
    Provider IO
syntheticOfflineProvider coordinate =
    Provider
        { withAcquired = \_ -> unusedOffline "withAcquired"
        , queryUTxOs = \_ -> unusedOffline "queryUTxOs"
        , queryUTxOByTxIn = \_ -> unusedOffline "queryUTxOByTxIn"
        , queryProtocolParams = unusedOffline "queryProtocolParams"
        , queryLedgerSnapshot = unusedOffline "queryLedgerSnapshot"
        , queryStakeRewards = \_ -> unusedOffline "queryStakeRewards"
        , queryRewardAccounts = \_ -> unusedOffline "queryRewardAccounts"
        , queryVoteDelegatees = \_ -> unusedOffline "queryVoteDelegatees"
        , queryTreasury = unusedOffline "queryTreasury"
        , queryGovernanceState = unusedOffline "queryGovernanceState"
        , evaluateTx = \_ -> unusedOffline "evaluateTx"
        , posixMsToSlot =
            withinProviderHorizon coordinate
                . syntheticFloorSlot coordinate
        , posixMsCeilSlot =
            withinProviderHorizon coordinate
                . syntheticCeilSlot coordinate
        , queryUpperBoundSlot = \_ ->
            unusedOffline "queryUpperBoundSlot"
        }
  where
    -- 'Provider' has strict fields, so an operation outside the
    -- bounded offline contract must be a real action that throws
    -- when called, not bottom at construction time.
    unusedOffline :: forall a. String -> IO a
    unusedOffline name =
        Exception.throwIO $
            Exception.ErrorCall $
                "synthetic offline provider: "
                    <> name
                    <> " is not part of \
                       \the bounded offline contract"

{- | Bound a computed candidate slot by the same
'syntheticHorizon' the fixture 'EpochInfo' enforces. A
candidate past it is a named failure, never a clamp, a
fallback, or an extrapolated coordinate.
-}
withinProviderHorizon ::
    SyntheticDevnetCoordinate ->
    SlotNo ->
    IO SlotNo
withinProviderHorizon coordinate candidate
    | unSlotNo candidate
        <= unSlotNo (syntheticHorizon coordinate) =
        pure candidate
    | otherwise =
        Exception.throwIO $
            Exception.ErrorCall $
                "synthetic offline provider: slot "
                    <> show (unSlotNo candidate)
                    <> " is past the bounded horizon"

-- | POSIX milliseconds of a slot start, from the source record.
syntheticSlotStartMs ::
    SyntheticDevnetCoordinate ->
    SlotNo ->
    Integer
syntheticSlotStartMs coordinate slot =
    posixMillisecondsOf (syntheticSystemStart coordinate)
        + toInteger (unSlotNo slot)
            * slotLengthMilliseconds
                (syntheticSlotLength coordinate)

-- | Floor POSIX milliseconds to a slot, from the source record.
syntheticFloorSlot ::
    SyntheticDevnetCoordinate ->
    Integer ->
    SlotNo
syntheticFloorSlot coordinate ms =
    SlotNo $
        fromInteger $
            max 0 $
                (ms - startMs) `div` slotMs
  where
    startMs =
        posixMillisecondsOf (syntheticSystemStart coordinate)
    slotMs =
        slotLengthMilliseconds (syntheticSlotLength coordinate)

-- | Ceiling POSIX milliseconds to a slot, from the source record.
syntheticCeilSlot ::
    SyntheticDevnetCoordinate ->
    Integer ->
    SlotNo
syntheticCeilSlot coordinate ms
    | (ms - startMs) `mod` slotMs == 0 = floorSlot
    | otherwise = SlotNo (unSlotNo floorSlot + 1)
  where
    floorSlot =
        syntheticFloorSlot coordinate ms
    startMs =
        posixMillisecondsOf (syntheticSystemStart coordinate)
    slotMs =
        slotLengthMilliseconds (syntheticSlotLength coordinate)

-- | POSIX milliseconds of a 'SystemStart'.
posixMillisecondsOf :: SystemStart -> Integer
posixMillisecondsOf start =
    round $
        1000
            * getRelativeTime
                ( toRelativeTime
                    posixEpochStart
                    (getSystemStart start)
                )

-- | Slot length in whole milliseconds.
slotLengthMilliseconds :: SlotLength -> Integer
slotLengthMilliseconds =
    round . (* 1000) . getSlotLength

{- | Floor a POSIX millisecond to a slot using only the
'Globals' 'EpochInfo', independently of the offline provider's
arithmetic.
-}
globalsFloorSlot ::
    Globals ->
    SlotNo ->
    Integer ->
    Either T.Text SlotNo
globalsFloorSlot globals horizon ms = do
    starts <-
        traverse relativeStart bounded
    case [slot | (slot, start) <- starts, start <= target] of
        [] ->
            Left "globalsFloorSlot: before the fixture origin"
        below ->
            Right (maximum below)
  where
    bounded =
        SlotNo <$> [0 .. unSlotNo horizon]
    relativeStart slot =
        (,) slot . getRelativeTime
            <$> epochInfoSlotToRelativeTime
                (epochInfo globals)
                slot
    target =
        fromInteger
            (ms - posixMillisecondsOf (systemStart globals))
            / 1000

{- | Ceiling a POSIX millisecond to a slot using only the
'Globals' 'EpochInfo'.
-}
globalsCeilSlot ::
    Globals ->
    SlotNo ->
    Integer ->
    Either T.Text SlotNo
globalsCeilSlot globals horizon ms = do
    slot <- globalsFloorSlot globals horizon ms
    start <-
        getRelativeTime
            <$> epochInfoSlotToRelativeTime
                (epochInfo globals)
                slot
    pure $
        if start == target
            then slot
            else SlotNo (unSlotNo slot + 1)
  where
    target =
        fromInteger
            (ms - posixMillisecondsOf (systemStart globals))
            / 1000

{- | Prove exact provider/'Globals' coordinate identity over the
whole bounded interval, and named failure past its horizon.
-}
assertSyntheticCoordinateIdentity ::
    SyntheticDevnetCoordinate ->
    Globals ->
    Provider IO ->
    IO ()
assertSyntheticCoordinateIdentity coordinate fixture offline = do
    mapM_ assertSlot bounded
    epochInfoFirst (epochInfo fixture) (EpochNo 0)
        `shouldBe` Right (SlotNo 0)
    epochInfoFirst (epochInfo fixture) (EpochNo 1)
        `shouldBe` Right (SlotNo 100)
    epochInfoSize (epochInfo fixture) (EpochNo 0)
        `shouldBe` Right (syntheticEpochLength coordinate)
    epochInfoEpoch (epochInfo fixture) (SlotNo 0)
        `shouldBe` Right (syntheticConwayStart coordinate)
    epochInfoSlotToRelativeTime
        (epochInfo fixture)
        (SlotNo (unSlotNo horizon + 1))
        `shouldSatisfy` isHorizonFailure
    epochInfoSlotLength
        (epochInfo fixture)
        (SlotNo (unSlotNo horizon + 1))
        `shouldSatisfy` isHorizonFailure
    -- The provider shares the bounded coordinate: at the POSIX
    -- start of the first slot past the horizon, both conversions
    -- fail with the named marker instead of extrapolating.
    beyondFloor <-
        Exception.try @Exception.ErrorCall $
            posixMsToSlot offline beyondHorizonMs
    beyondCeil <-
        Exception.try @Exception.ErrorCall $
            posixMsCeilSlot offline beyondHorizonMs
    boundedHorizonFailure beyondFloor
        `shouldBe` True
    boundedHorizonFailure beyondCeil
        `shouldBe` True
  where
    horizon = syntheticHorizon coordinate
    bounded = SlotNo <$> [0 .. unSlotNo horizon]
    beyondHorizonMs =
        syntheticSlotStartMs
            coordinate
            (SlotNo (unSlotNo horizon + 1))
    slotMs =
        slotLengthMilliseconds (syntheticSlotLength coordinate)
    assertSlot slot = do
        let startMs =
                syntheticSlotStartMs coordinate slot
            midMs = startMs + slotMs `div` 2
        -- exact slot boundary: floor and ceiling agree
        providerFloor <- posixMsToSlot offline startMs
        providerCeil <- posixMsCeilSlot offline startMs
        providerFloor `shouldBe` slot
        providerCeil `shouldBe` slot
        globalsFloorSlot fixture horizon startMs
            `shouldBe` Right slot
        globalsCeilSlot fixture horizon startMs
            `shouldBe` Right slot
        -- inside the slot: floor stays, ceiling advances
        midFloor <- posixMsToSlot offline midMs
        midFloor `shouldBe` slot
        globalsFloorSlot fixture horizon midMs
            `shouldBe` Right slot
        -- coordinate derived from the source record
        epochInfoEpoch (epochInfo fixture) slot
            `shouldBe` Right
                (EpochNo (unSlotNo slot `div` 100))
        (getSlotLength <$> epochInfoSlotLength (epochInfo fixture) slot)
            `shouldBe` Right 0.1
        epochInfoSlotToRelativeTime (epochInfo fixture) slot
            `shouldBe` Right
                ( RelativeTime $
                    fromIntegral (unSlotNo slot) * 0.1
                )

-- | A bounded-horizon failure, not a fabricated coordinate.
isHorizonFailure :: Either T.Text a -> Bool
isHorizonFailure (Left message) =
    T.isInfixOf "past the bounded horizon" message
isHorizonFailure _ = False

{- | The synthetic provider refused a candidate past its bounded
horizon with the named marker, rather than returning a slot.
-}
boundedHorizonFailure ::
    Either Exception.ErrorCall SlotNo ->
    Bool
boundedHorizonFailure (Left err) =
    T.isInfixOf
        "past the bounded horizon"
        (T.pack (show err))
boundedHorizonFailure _ = False

{- | Offline analogue of the acquisition callback: one 'Globals'
and one provider reach every consumer.
-}
withSyntheticSnapshot ::
    Globals ->
    Provider IO ->
    (Globals -> Provider IO -> IO a) ->
    IO a
withSyntheticSnapshot globals provider callback =
    callback globals provider

-- | Mock builder step; returns the 'Globals' it was handed.
mockBuilderStep :: Globals -> Provider IO -> IO Globals
mockBuilderStep globals provider = do
    slot <- posixMsToSlot provider 0
    void $ Exception.evaluate slot
    pure globals

-- | Mock ledger-native guard step; returns the same 'Globals'.
mockGuardStep :: Globals -> IO Globals
mockGuardStep globals = do
    void $
        Exception.evaluate
            (epochInfoEpoch (epochInfo globals) (SlotNo 0))
    pure globals

-- | Copy a genesis directory tree into a fresh location.
copyGenesisTree :: FilePath -> FilePath -> IO ()
copyGenesisTree source target = do
    createDirectoryIfMissing True target
    entries <- listDirectory source
    mapM_ copyEntry entries
  where
    copyEntry entry = do
        let from = source </> entry
            to = target </> entry
        isDir <- doesDirectoryExist from
        if isDir
            then copyGenesisTree from to
            else copyFile from to

{- | Move the Conway hard fork one epoch later so the node
starts before Conway.
-}
delayConwayHardFork :: FilePath -> IO ()
delayConwayHardFork dir = do
    raw <- BS.readFile configPath
    let patched =
            T.replace
                "\"TestConwayHardForkAtEpoch\": 0"
                "\"TestConwayHardForkAtEpoch\": 1"
                (TE.decodeUtf8 raw)
    permissions <- getPermissions configPath
    setPermissions configPath (setOwnerWritable True permissions)
    BS.writeFile configPath (TE.encodeUtf8 patched)
  where
    configPath = dir </> "node-config.json"

{- | The era mismatch must surface as the implementation's named
failure, not as fixture data.
-}
eraMismatchReported ::
    Either Exception.ErrorCall a ->
    Bool
eraMismatchReported (Left err) =
    "era mismatch" `T.isInfixOf` T.pack (show err)
eraMismatchReported _ = False

{- | The implementation must not read a clock or carry a
reconstructed timestamp.
-}
assertNoClockProvenance :: BS.ByteString -> IO ()
assertNoClockProvenance source =
    mapM_ absent forbidden
  where
    text = TE.decodeUtf8 source
    forbidden =
        [ "getCurrentTime"
        , "getPOSIXTime"
        , "getSystemTime"
        , "getMonotonicTime"
        , "2026-07-26"
        ]
    absent needle =
        T.isInfixOf needle text
            `shouldBe` False

slotNumber :: SlotNo -> Word64
slotNumber (SlotNo slot) =
    slot

epochNumber :: EpochNo -> Word64
epochNumber (EpochNo epoch) =
    epoch
