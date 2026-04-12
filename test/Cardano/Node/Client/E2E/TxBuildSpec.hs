{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

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
import Cardano.Ledger.Address (Addr)
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
    StrictMaybe (SJust),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
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
    build,
    ctx,
    payTo,
    payTo',
    peek,
    requireSignature,
    spend,
    valid,
    validFrom,
    validTo,
 )
import Cardano.Slotting.Slot (SlotNo (..))

spec :: Spec
spec =
    around withEnv $
        describe "TxBuild E2E" $
            it
                "builds and submits a fee-dependent tx with signer and validity constraints"
                buildAndSubmit

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
