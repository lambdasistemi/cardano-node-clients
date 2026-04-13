{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Node.Client.E2E.TxBuildSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SignKeyDSIGN,
    deriveVerKeyDSIGN,
 )
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (NoDatum))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    vldtTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    StrictMaybe (SJust),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (Witness),
    VKey (..),
    asWitness,
    hashKey,
 )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    enterpriseAddr,
    genesisAddr,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
    withDevnet,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxBuild (
    Check (..),
    Convergence (..),
    InterpretIO (..),
    TxBuild,
    attachScript,
    build,
    collateral,
    ctx,
    output,
    payTo,
    payTo',
    peek,
    requireSignature,
    spend,
    spendScript,
    valid,
    validFrom,
    validTo,
 )
import Cardano.Slotting.Slot (SlotNo (..))

import Cardano.Ledger.Alonzo.Scripts (
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (
    Language (..),
    Plutus (..),
    PlutusBinary (..),
 )
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Maybe (fromJust)

spec :: Spec
spec =
    around withEnv $
        describe "TxBuild E2E" $ do
            it
                "builds and submits a fee-dependent tx with signer and validity constraints"
                buildAndSubmit
            it
                "builds and submits a Plutus script tx with real ExUnits"
                scriptSpendE2E

type Env =
    ( Provider IO
    , Submitter IO
    , PParams ConwayEra
    , [(TxIn, TxOut ConwayEra)]
    )

withEnv :: (Env -> IO ()) -> IO ()
withEnv action =
    withDevnet $ \lsq ltxs -> do
        let provider = mkN2CProvider lsq
            submitter = mkN2CSubmitter ltxs
        pp <- queryProtocolParams provider
        utxos <- queryUTxOs provider genesisAddr
        action (provider, submitter, pp, utxos)

data TestQ a where
    PlainOutputCoin :: TestQ Coin
    DatumBaseCoin :: TestQ Coin
    DatumTag :: TestQ Integer

data TestErr
    = MissingRequiredSigner
    | NonPositiveFee
    deriving stock (Eq, Show)

buildAndSubmit :: Env -> IO ()
buildAndSubmit (provider, submitter, pp, utxos) = do
    seed@(seedIn, _) <- case utxos of
        u : _ -> pure u
        [] -> fail "no genesis UTxOs"

    let recipient1 =
            enterpriseAddr $
                keyHashFromSignKey $
                    mkSignKey (BS8.pack (replicate 32 '1'))
        recipient2 =
            enterpriseAddr $
                keyHashFromSignKey $
                    mkSignKey (BS8.pack (replicate 32 '2'))
        signer =
            witnessKeyHashFromSignKey genesisSignKey
        lower = SlotNo 0
        upper = SlotNo 1_000_000
        plainCoin = Coin 3_000_000
        datumBase = Coin 2_500_000
        datumValue = (7 :: Integer)
        interpret =
            InterpretIO $ \case
                PlainOutputCoin -> pure plainCoin
                DatumBaseCoin -> pure datumBase
                DatumTag -> pure datumValue
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        prog :: TxBuild TestQ TestErr ()
        prog = do
            _ <- spend seedIn
            plain <- ctx PlainOutputCoin
            base <- ctx DatumBaseCoin
            tag <- ctx DatumTag
            Coin fee <- peek $ \tx ->
                let currentFee =
                        tx ^. bodyTxL . feeTxBodyL
                 in if currentFee > Coin 0
                        then Ok currentFee
                        else Iterate currentFee
            _ <-
                payTo recipient1 (inject plain)
            _ <-
                payTo'
                    recipient2
                    (inject (Coin (unCoin base + fee)))
                    tag
            requireSignature signer
            validFrom lower
            validTo upper
            valid $ \tx ->
                if Set.member
                    signer
                    (tx ^. bodyTxL . reqSignerHashesTxBodyL)
                    then
                        if tx ^. bodyTxL . feeTxBodyL > Coin 0
                            then Pass
                            else CustomFail NonPositiveFee
                    else
                        CustomFail MissingRequiredSigner
            pure ()

    build pp interpret eval [seed] genesisAddr prog
        >>= \case
            Left err ->
                expectationFailure (show err)
            Right tx -> do
                let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
                    fee = tx ^. bodyTxL . feeTxBodyL
                length outs `shouldBe` 3
                tx ^. bodyTxL . reqSignerHashesTxBodyL
                    `shouldBe` Set.singleton signer
                tx ^. bodyTxL . vldtTxBodyL
                    `shouldBe` ValidityInterval
                        { invalidBefore = SJust lower
                        , invalidHereafter = SJust upper
                        }
                case outs of
                    [plainOut, datumOut, _changeOut] -> do
                        plainOut ^. coinTxOutL
                            `shouldBe` plainCoin
                        datumOut ^. coinTxOutL
                            `shouldBe` Coin
                                ( unCoin datumBase
                                    + unCoin fee
                                )
                        datumOut ^. datumTxOutL
                            `shouldNotBe` NoDatum
                    _ ->
                        expectationFailure
                            "expected plain, datum, and change outputs"

                let signed =
                        addKeyWitness genesisSignKey tx
                submitTx submitter signed
                    >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            expectationFailure $
                                "submitTx rejected: "
                                    <> show reason

                recipient1Utxos <-
                    waitForUtxos provider recipient1 30
                recipient2Utxos <-
                    waitForUtxos provider recipient2 30

                case (recipient1Utxos, recipient2Utxos) of
                    ((_, out1) : _, (_, out2) : _) -> do
                        out1 ^. coinTxOutL
                            `shouldBe` plainCoin
                        out2 ^. coinTxOutL
                            `shouldBe` Coin
                                ( unCoin datumBase
                                    + unCoin fee
                                )
                        out2 ^. datumTxOutL
                            `shouldNotBe` NoDatum
                    _ ->
                        expectationFailure
                            "expected recipient UTxOs"

waitForUtxos ::
    Provider IO ->
    Addr ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForUtxos provider addr attempts
    | attempts <= 0 =
        expectationFailure
            ("timed out waiting for UTxOs at " <> show addr)
            >> pure []
    | otherwise = do
        utxos <- queryUTxOs provider addr
        if null utxos
            then do
                threadDelay 1_000_000
                waitForUtxos provider addr (attempts - 1)
            else pure utxos

witnessKeyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash 'Witness
witnessKeyHashFromSignKey =
    hashKey
        . asWitness
        . VKey
        . deriveVerKeyDSIGN

-- | Always-succeeds PlutusV3 script compiled with Aiken.
alwaysSucceedsScript :: Script ConwayEra
alwaysSucceedsScript =
    let hexBytes = case B16.decode
            "585c01010029800aba2aba1aab9eaab9d\
            \ab9a4888896600264653001300600198\
            \031803800cc0180092225980099b87480\
            \08c01cdd500144c8cc89289805000980\
            \5180580098041baa0028b200c18030009\
            \8019baa0068a4d13656400401" of
            Right bs -> bs
            Left err -> error err
        pb = PlutusBinary (SBS.toShort hexBytes)
        ps =
            fromJust $
                mkPlutusScript @ConwayEra
                    (Plutus @'PlutusV3 pb)
     in fromPlutusScript ps

{- | E2E test: build and submit a Plutus script tx.

1. Send ADA to the script address
2. Spend from the script using spendScript + build
3. Verify ExUnits are patched and fee is correct
4. Submit and verify accepted
-}
scriptSpendE2E :: Env -> IO ()
scriptSpendE2E (provider, submitter, pp, utxos) = do
    seed@(seedIn, _) <- case utxos of
        u : _ -> pure u
        [] -> fail "no genesis UTxOs"
    -- Step 1: Send ADA to the script address
    let script = alwaysSucceedsScript
        scriptHash = hashScript script
        scriptAddr =
            Addr
                Testnet
                (ScriptHashObj scriptHash)
                StakeRefNull
        scriptOut =
            mkBasicTxOut
                scriptAddr
                (inject (Coin 5_000_000))
        fundProg :: TxBuild TestQ TestErr ()
        fundProg = do
            _ <- spend seedIn
            _ <- output scriptOut
            pure ()
        fundEval _ = pure Map.empty
        fundInterpret =
            InterpretIO $ \case
                PlainOutputCoin -> pure (Coin 0)
                DatumBaseCoin -> pure (Coin 0)
                DatumTag -> pure 0
    fundResult <-
        build
            pp
            fundInterpret
            fundEval
            [seed]
            genesisAddr
            fundProg
    fundTx <- case fundResult of
        Left err -> fail $ show err
        Right tx -> pure tx
    let fundSigned =
            addKeyWitness genesisSignKey fundTx
    submitTx submitter fundSigned >>= \case
        Submitted _ -> pure ()
        Rejected r ->
            fail $ "fund script: " <> show r
    -- Wait for UTxO at script address
    scriptUtxos <-
        waitForUtxos provider scriptAddr 30
    (scriptIn, scriptOut') <- case scriptUtxos of
        u : _ -> pure u
        [] -> fail "no script UTxOs"
    -- Get fresh wallet UTxOs for fee
    walletUtxos <-
        queryUTxOs provider genesisAddr
    feeUtxo@(feeIn, _) <- case walletUtxos of
        u : _ -> pure u
        [] -> fail "no wallet UTxOs"
    -- Step 2: Spend from script
    let spendProg :: TxBuild TestQ TestErr ()
        spendProg = do
            _ <-
                spendScript
                    scriptIn
                    (42 :: Integer)
            _ <-
                payTo
                    genesisAddr
                    (inject (Coin 3_000_000))
            attachScript script
            collateral feeIn
            pure ()
        spendEval tx =
            fmap
                ( Map.map
                    (either (Left . show) Right)
                )
                (evaluateTx provider tx)
    spendResult <-
        build
            pp
            fundInterpret
            spendEval
            [feeUtxo, (scriptIn, scriptOut')]
            genesisAddr
            spendProg
    spendTx <- case spendResult of
        Left err -> fail $ show err
        Right tx -> pure tx
    -- Verify ExUnits are patched
    let Redeemers rdmrs =
            spendTx ^. witsTxL . rdmrsTxWitsL
        allEUs =
            [eu | (_, (_, eu)) <- Map.toList rdmrs]
    all (\(ExUnits m s) -> m > 0 && s > 0) allEUs
        `shouldBe` True
    -- Verify fee > 0
    let Coin fee =
            spendTx ^. bodyTxL . feeTxBodyL
    fee `shouldSatisfy` (> 0)
    -- Step 3: Submit
    let spendSigned =
            addKeyWitness genesisSignKey spendTx
    submitTx submitter spendSigned >>= \case
        Submitted _ -> pure ()
        Rejected r ->
            fail $ "spend script: " <> show r
