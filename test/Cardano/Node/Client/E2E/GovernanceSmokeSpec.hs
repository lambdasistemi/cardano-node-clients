{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.GovernanceSmokeSpec
Description : Devnet governance smoke test
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.GovernanceSmokeSpec (spec) where

import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SignKeyDSIGN,
    deriveVerKeyDSIGN,
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
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    StrictMaybe (SNothing),
    textToUrl,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (DRepRole, Payment, Staking),
    VKey (..),
    hashKey,
 )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    genesisAddr,
    genesisDir,
    genesisSignKey,
    mkSignKey,
    withDevnetFromGenesis,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (
    EpochNo (..),
    LedgerSnapshot (..),
    Provider (..),
 )
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxBuild (
    CertWitness (..),
    ConwayDelegCert (..),
    ConwayGovCert (..),
    ConwayTxCert (..),
    DRep (..),
    Delegatee (..),
    GovActionId (..),
    GovActionIx (..),
    InterpretIO (..),
    ProposalWitness (..),
    TxBuild,
    Vote (..),
    Voter (..),
    build,
    certify,
    payTo,
    proposeTreasuryWithdrawal,
    registerAndVoteAbstain,
    spend,
    validTo,
    vote,
 )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Void (Void)
import Data.Word (Word64, Word8)
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    getPermissions,
    setPermissions,
    writable,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    around,
    describe,
    expectationFailure,
    it,
    shouldBe,
 )

spec :: Spec
spec =
    around withGovernanceEnv $
        describe "DevNet governance smoke" $
            it
                "submits a treasury withdrawal and observes the target reward after an epoch"
                submitTreasuryWithdrawal

type Env =
    ( Provider IO
    , Submitter IO
    , PParams ConwayEra
    , [(TxIn, TxOut ConwayEra)]
    )

data NoCtx a

withdrawalAmount :: Coin
withdrawalAmount = Coin 2_000_000

stakeDeposit :: Coin
stakeDeposit = Coin 400_000

governanceDeposit :: Coin
governanceDeposit = Coin 1_000_000

drepDeposit :: Coin
drepDeposit = Coin 500_000

stakeOutputCoin :: Coin
stakeOutputCoin = Coin 5_000_000

targetSignKey :: SignKeyDSIGN Ed25519DSIGN
targetSignKey =
    mkSignKey "e2e-governance-target-key-000001"

withGovernanceEnv :: (Env -> IO ()) -> IO ()
withGovernanceEnv action =
    withGovernanceGenesis $ \gDir ->
        withDevnetFromGenesis gDir $ \lsq ltxs -> do
            let provider =
                    mkN2CProvider lsq
                submitter =
                    mkN2CSubmitter ltxs
            _ <- waitForTreasury provider withdrawalAmount 120
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider genesisAddr
            action (provider, submitter, pp, utxos)

submitTreasuryWithdrawal :: Env -> IO ()
submitTreasuryWithdrawal (provider, submitter, pp, utxos) = do
    seed@(seedIn, _) <- case utxos of
        u : _ -> pure u
        [] -> fail "no genesis UTxOs"

    let returnAccount =
            rewardAccountFromSignKey genesisSignKey
        targetAccount =
            rewardAccountFromSignKey targetSignKey
        targetCredential =
            stakeCredentialFromSignKey targetSignKey
        returnCredential =
            stakeCredentialFromSignKey genesisSignKey
        drepCredential =
            drepCredentialFromSignKey targetSignKey
        drepKey =
            drepKeyHashFromSignKey targetSignKey
        targetBaseAddr =
            baseAddrFromSignKey targetSignKey targetCredential
        interpret :: InterpretIO NoCtx
        interpret =
            InterpretIO $ \case {}
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            _ <-
                registerAndVoteAbstain
                    returnCredential
                    stakeDeposit
                    PubKeyCert
            _ <-
                certify
                    ( ConwayTxCertGov $
                        ConwayRegDRep
                            drepCredential
                            drepDeposit
                            SNothing
                    )
                    PubKeyCert
            _ <-
                certify
                    ( ConwayTxCertDeleg $
                        ConwayRegDelegCert
                            targetCredential
                            (DelegVote (DRepKeyHash drepKey))
                            stakeDeposit
                    )
                    PubKeyCert
            _ <-
                payTo
                    targetBaseAddr
                    (inject stakeOutputCoin)
            _ <-
                proposeTreasuryWithdrawal
                    governanceDeposit
                    returnAccount
                    governanceAnchor
                    (Map.singleton targetAccount withdrawalAmount)
                    SNothing
                    NoProposalScript
            validTo (SlotNo 1_000_000)

    rewardBefore <- rewardBalance provider targetAccount
    build pp interpret eval [seed] [] genesisAddr prog
        >>= \case
            Left err ->
                expectationFailure (show err)
            Right tx -> do
                let signed =
                        addKeyWitness targetSignKey $
                            addKeyWitness genesisSignKey tx
                    setupTxId =
                        txIdTx signed
                submitTx submitter signed
                    >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            expectationFailure $
                                "submitTx rejected: "
                                    <> show reason
                waitForTxChange provider setupTxId genesisAddr 60
                setupSnapshot <- queryLedgerSnapshot provider
                waitForEpochAfter
                    provider
                    (ledgerEpoch setupSnapshot)
                    60
                voteUtxos <-
                    waitForUtxos provider targetBaseAddr 60
                voteSeed <- case voteUtxos of
                    u : _ -> pure u
                    [] -> fail "target base UTxO disappeared"
                let actionId =
                        GovActionId setupTxId (GovActionIx 0)
                submitVote
                    provider
                    submitter
                    pp
                    targetBaseAddr
                    voteSeed
                    drepCredential
                    actionId
                voteSnapshot <- queryLedgerSnapshot provider
                rewardAfter <-
                    waitForRewardIncrease
                        provider
                        targetAccount
                        (ledgerEpoch voteSnapshot)
                        rewardBefore
                        withdrawalAmount
                        180
                rewardAfter `shouldBe` addCoin rewardBefore withdrawalAmount

submitVote ::
    Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    Addr ->
    (TxIn, TxOut ConwayEra) ->
    Credential DRepRole ->
    GovActionId ->
    IO ()
submitVote
    provider
    submitter
    pp
    targetBaseAddr
    seed@(seedIn, _)
    drepCredential
    actionId = do
        let interpret :: InterpretIO NoCtx
            interpret =
                InterpretIO $ \case {}
            eval tx =
                fmap
                    (Map.map (either (Left . show) Right))
                    (evaluateTx provider tx)
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend seedIn
                vote
                    (DRepVoter drepCredential)
                    actionId
                    VoteYes
                    SNothing
                validTo (SlotNo 1_000_000)
        build
            pp
            interpret
            eval
            [seed]
            []
            targetBaseAddr
            prog
            >>= \case
                Left err ->
                    expectationFailure (show err)
                Right tx -> do
                    let signed =
                            addKeyWitness targetSignKey tx
                        txId =
                            txIdTx signed
                    submitTx submitter signed
                        >>= \case
                            Submitted _ -> pure ()
                            Rejected reason ->
                                expectationFailure $
                                    "submitVote rejected: "
                                        <> show reason
                    waitForTxChange provider txId targetBaseAddr 60

governanceAnchor :: Anchor
governanceAnchor =
    Anchor
        ( fromJust $
            textToUrl
                128
                "https://example.invalid/devnet-governance-smoke.json"
        )
        (unsafeMakeSafeHash (mkHash32 42))

rewardAccountFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    AccountAddress
rewardAccountFromSignKey sk =
    AccountAddress
        Testnet
        (AccountId (stakeCredentialFromSignKey sk))

stakeCredentialFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    Credential Staking
stakeCredentialFromSignKey =
    KeyHashObj . stakeKeyHashFromSignKey

stakeKeyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash Staking
stakeKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

drepCredentialFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    Credential DRepRole
drepCredentialFromSignKey =
    KeyHashObj . drepKeyHashFromSignKey

drepKeyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash DRepRole
drepKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

paymentKeyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash Payment
paymentKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

baseAddrFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    Credential Staking ->
    Addr
baseAddrFromSignKey sk stakeCredential =
    Addr
        Testnet
        (KeyHashObj (paymentKeyHashFromSignKey sk))
        (StakeRefBase stakeCredential)

rewardBalance ::
    Provider IO ->
    AccountAddress ->
    IO Coin
rewardBalance provider account =
    Map.findWithDefault (Coin 0) account
        <$> queryRewardAccounts provider (Set.singleton account)

waitForTreasury ::
    Provider IO ->
    Coin ->
    Int ->
    IO Coin
waitForTreasury _ minimumCoin attempts
    | attempts <= 0 =
        expectationFailure
            ( "timed out waiting for treasury >= "
                <> show minimumCoin
            )
            >> pure (Coin 0)
waitForTreasury provider minimumCoin attempts = do
    treasury <- queryTreasury provider
    if treasury >= minimumCoin
        then pure treasury
        else do
            threadDelay 500_000
            waitForTreasury provider minimumCoin (attempts - 1)

waitForUtxos ::
    Provider IO ->
    Addr ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForUtxos _ addr attempts
    | attempts <= 0 =
        expectationFailure
            ("timed out waiting for UTxOs at " <> show addr)
            >> pure []
waitForUtxos provider addr attempts = do
    utxos <- queryUTxOs provider addr
    if null utxos
        then do
            threadDelay 500_000
            waitForUtxos provider addr (attempts - 1)
        else pure utxos

waitForTxChange ::
    Provider IO ->
    TxId ->
    Addr ->
    Int ->
    IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        expectationFailure $
            "timed out waiting for tx change output: " <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

waitForEpochAfter ::
    Provider IO ->
    EpochNo ->
    Int ->
    IO ()
waitForEpochAfter _ epoch attempts
    | attempts <= 0 =
        expectationFailure
            ("timed out waiting for epoch after " <> show epoch)
waitForEpochAfter provider epoch attempts = do
    snapshot <- queryLedgerSnapshot provider
    if epochNumber (ledgerEpoch snapshot) > epochNumber epoch
        then pure ()
        else do
            threadDelay 500_000
            waitForEpochAfter provider epoch (attempts - 1)

waitForRewardIncrease ::
    Provider IO ->
    AccountAddress ->
    EpochNo ->
    Coin ->
    Coin ->
    Int ->
    IO Coin
waitForRewardIncrease _ account _ _ expected attempts
    | attempts <= 0 =
        expectationFailure
            ( "timed out waiting for treasury withdrawal at "
                <> show account
                <> " to increase by "
                <> show expected
            )
            >> pure (Coin 0)
waitForRewardIncrease
    provider
    account
    submittedEpoch
    before
    expected
    attempts = do
        snapshot <- queryLedgerSnapshot provider
        after <- rewardBalance provider account
        if epochNumber (ledgerEpoch snapshot)
            > epochNumber submittedEpoch
            && after == addCoin before expected
            then pure after
            else do
                threadDelay 500_000
                waitForRewardIncrease
                    provider
                    account
                    submittedEpoch
                    before
                    expected
                    (attempts - 1)

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addCoin :: Coin -> Coin -> Coin
addCoin (Coin a) (Coin b) =
    Coin (a + b)

epochNumber :: EpochNo -> Word64
epochNumber (EpochNo epoch) =
    epoch

withGovernanceGenesis :: (FilePath -> IO a) -> IO a
withGovernanceGenesis action = do
    source <- genesisDir
    withSystemTempDirectory "cardano-governance-genesis" $
        \dir -> do
            copyGenesisSource source dir
            patchGenesis dir
            action dir

copyGenesisSource :: FilePath -> FilePath -> IO ()
copyGenesisSource source target = do
    createDirectoryIfMissing True target
    createDirectoryIfMissing True (target </> "delegate-keys")
    traverse_
        copyGenesisFile
        [ "alonzo-genesis.json"
        , "byron-genesis.json"
        , "conway-genesis.json"
        , "dijkstra-genesis.json"
        , "node-config.json"
        , "shelley-genesis.json"
        , "topology.json"
        ]
    traverse_
        copyDelegateKey
        [ "delegate1.kes.skey"
        , "delegate1.opcert"
        , "delegate1.vrf.skey"
        ]
  where
    copyGenesisFile name =
        copyWritableFile (source </> name) (target </> name)
    copyDelegateKey name =
        copyWritableFile
            (source </> "delegate-keys" </> name)
            (target </> "delegate-keys" </> name)

copyWritableFile :: FilePath -> FilePath -> IO ()
copyWritableFile source target = do
    copyFile source target
    permissions <- getPermissions target
    setPermissions target permissions{writable = True}

patchGenesis :: FilePath -> IO ()
patchGenesis dir = do
    patchFile
        (dir </> "shelley-genesis.json")
        [ ("\"epochLength\": 500", "\"epochLength\": 50")
        ,
            ( "\"maxLovelaceSupply\": 30000000000000000"
            , "\"maxLovelaceSupply\": 60000000000000000"
            )
        ]
    patchFile
        (dir </> "conway-genesis.json")
        [ ("\"treasuryWithdrawal\": 0.67", "\"treasuryWithdrawal\": 0.0")
        , ("\"committeeMinSize\": 7", "\"committeeMinSize\": 0")
        ,
            ( "\"committee\": {\n    \"members\": {\n    },\n    \"threshold\": 0.67\n  }"
            , "\"committee\": {\n    \"members\": {\n      \"keyHash-4e88cc2d27c364aaf90648a87dfb95f8ee103ba67fa1f12f5e86c42a\": 100000\n    },\n    \"threshold\": 0.0\n  }"
            )
        ,
            ( "\"dRepDeposit\": 500000000"
            , "\"dRepDeposit\": 500000"
            )
        ,
            ( "\"govActionDeposit\": 50000000000"
            , "\"govActionDeposit\": 1000000"
            )
        ]

patchFile ::
    FilePath ->
    [(BS.ByteString, BS.ByteString)] ->
    IO ()
patchFile path replacements = do
    content <- BS.readFile path
    BS.writeFile path $
        foldl'
            ( \bytes (needle, replacement) ->
                replaceRequired needle replacement bytes
            )
            content
            replacements

replaceRequired ::
    BS.ByteString ->
    BS.ByteString ->
    BS.ByteString ->
    BS.ByteString
replaceRequired needle replacement content =
    let (before, after) =
            BS.breakSubstring needle content
     in if BS.null after
            then
                error $
                    "governance smoke genesis patch did not find "
                        <> BS8.unpack needle
            else
                before
                    <> replacement
                    <> BS.drop (BS.length needle) after

mkHash32 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 31 0 ++ [n]
