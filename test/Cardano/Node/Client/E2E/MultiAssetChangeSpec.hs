{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.MultiAssetChangeSpec
Description : E2E test: balanceTx folds minted NFT into change.

Exercises the residual-multi-asset folding added to 'balanceTx'.
A spawn-style transaction:

  * spends a genesis UTxO,
  * mints 1 unit of an always-true policy with no explicit
    recipient output,
  * pays a fixed-coin output to a third-party recipient.

Without the folding patch, the balancer would emit an ADA-only
change output and the ledger would reject the tx with
'ValueNotConserved' (the minted token has no destination). With
the patch, the change output absorbs the NFT and the tx is
accepted on the devnet.
-}
module Cardano.Node.Client.E2E.MultiAssetChangeSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Void (Void)
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MaryValue (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
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
    InterpretIO (..),
    TxBuild,
    attachScript,
    build,
    collateral,
    mint,
    payTo,
    spend,
 )

spec :: Spec
spec =
    around withEnv $
        describe "balanceTx multi-asset change folding (E2E)" $
            it
                "folds minted NFT into change output and submits successfully"
                mintsNftIntoChange

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

-- | A Plutus V3 always-true minting policy (215 bytes of CBOR).
alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            either error id $
                Base16.decode (BS8.filter (/= '\n') alwaysTrueHex)
        plutus =
            Plutus @PlutusV3
                (PlutusBinary (SBS.toShort bytes))
     in maybe
            (error "alwaysTrueScript: mkPlutusScript")
            fromPlutusScript
            (mkPlutusScript plutus)

alwaysTrueHex :: BS8.ByteString
alwaysTrueHex =
    "58d501010029800aba2aba1aab9eaab9dab9a48888966002646465\
    \300130053754003300700398038012444b30013370e9000001c4c\
    \9289bae300a3009375400915980099b874800800e2646644944c0\
    \2c004c02cc030004c024dd5002456600266e1d200400389925130\
    \0a3009375400915980099b874801800e2646644944dd698058009\
    \805980600098049baa0048acc004cdc3a40100071324a26014601\
    \26ea80122646644944dd698058009805980600098049baa004401\
    \c8039007200e401c3006300700130060013003375400d149a26ca\
    \c8009"

mintsNftIntoChange :: Env -> IO ()
mintsNftIntoChange (provider, submitter, pp, utxos) = do
    seed@(seedIn, _) <- case utxos of
        u : _ -> pure u
        [] -> fail "no genesis UTxOs"
    let recipient =
            enterpriseAddr $
                keyHashFromSignKey $
                    mkSignKey
                        (BS8.pack (replicate 32 'r'))
        policyHash :: ScriptHash
        policyHash = hashScript alwaysTrueScript
        policy = PolicyID policyHash
        nftName =
            AssetName (SBS.toShort (BS8.pack "PILOT0"))
        recipientCoin = Coin 3_000_000
        interpret :: InterpretIO NoQ
        interpret = InterpretIO $ \case {}
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        prog :: TxBuild NoQ Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            attachScript alwaysTrueScript
            -- Mint without an explicit recipient
            -- output for the NFT — the balancer must
            -- fold it into the change output.
            mint policy (Map.singleton nftName 1) ()
            _ <- payTo recipient (inject recipientCoin)
            pure ()

    build pp interpret eval [seed] [] genesisAddr prog
        >>= \case
            Left err -> expectationFailure (show err)
            Right tx -> do
                let outs =
                        toList
                            (tx ^. bodyTxL . outputsTxBodyL)
                length outs `shouldBe` 2
                case outs of
                    [recipientOut, changeOut] -> do
                        recipientOut ^. coinTxOutL
                            `shouldBe` recipientCoin
                        let MaryValue _ recipientMA =
                                recipientOut ^. valueTxOutL
                            MaryValue _ changeMA =
                                changeOut ^. valueTxOutL
                            expectedMA =
                                MultiAsset $
                                    Map.singleton
                                        policy
                                        (Map.singleton nftName 1)
                        recipientMA `shouldBe` mempty
                        changeMA `shouldBe` expectedMA
                    _ ->
                        expectationFailure
                            "expected recipient + change outputs"

                let signed = addKeyWitness genesisSignKey tx
                submitTx submitter signed
                    >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            expectationFailure $
                                "submitTx rejected: "
                                    <> show reason

                changeUtxos <-
                    waitForUtxoWithMA
                        provider
                        genesisAddr
                        policy
                        nftName
                        30
                case changeUtxos of
                    [] ->
                        expectationFailure
                            "no change UTxO with the minted NFT \
                            \appeared at genesisAddr"
                    (_, out) : _ -> do
                        let MaryValue _ ma =
                                out ^. valueTxOutL
                            MultiAsset entries = ma
                        Map.lookup policy entries
                            `shouldBe` Just
                                (Map.singleton nftName 1)

-- | Phantom query GADT — this test has no @ctx@ queries.
data NoQ a

waitForUtxoWithMA ::
    Provider IO ->
    Addr ->
    PolicyID ->
    AssetName ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForUtxoWithMA provider addr policy name attempts
    | attempts <= 0 = pure []
    | otherwise = do
        utxos <- queryUTxOs provider addr
        let matching =
                [ (i, o)
                | (i, o) <- utxos
                , let MaryValue _ (MultiAsset m) =
                        o ^. valueTxOutL
                , case Map.lookup policy m of
                    Just inner ->
                        Map.lookup name inner == Just 1
                    Nothing -> False
                ]
        if null matching
            then do
                threadDelay 1_000_000
                waitForUtxoWithMA
                    provider
                    addr
                    policy
                    name
                    (attempts - 1)
            else pure matching
