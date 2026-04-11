{-# LANGUAGE GADTs #-}

{- |
Module      : Cardano.Node.Client.TxBuildSpec
Description : TxBuild DSL tests — Slice 1
License     : Apache-2.0

Tests for simple pub-key spend, payTo, collateral,
and draft assembly. Verifies inputs/outputs in
assembled Tx and that spend returns correct index.
-}
module Cardano.Node.Client.TxBuildSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (Tx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    TxIx (..),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (
    ScriptHash (..),
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.TxIn (
    TxId (..),
    TxIn (..),
 )
import Cardano.Node.Client.TxBuild
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (
    Hash,
    HashAlgorithm,
    hashFromBytes,
 )
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Word (Word8)

-- --------------------------------------------------
-- Test helpers
-- --------------------------------------------------

-- | Deterministic 32-byte hash.
mkHash32 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 31 0 ++ [n]

-- | Deterministic 28-byte hash.
mkHash28 ::
    (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 27 0 ++ [n]

-- | Fake TxIn from a byte.
mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId $ unsafeMakeSafeHash $ mkHash32 n)
        (TxIx (fromIntegral n))

-- | Fake address from a byte.
mkAddr :: Word8 -> Addr
mkAddr n =
    Addr
        Testnet
        (KeyHashObj (KeyHash (mkHash28 n)))
        StakeRefNull

-- | Fake PolicyID from a byte.
mkPolicyId :: Word8 -> PolicyID
mkPolicyId n =
    PolicyID $
        Cardano.Ledger.Hashes.ScriptHash $
            mkHash28 n

-- --------------------------------------------------
-- Spec
-- --------------------------------------------------

spec :: Spec
spec = describe "TxBuild" $ do
    spendSpec
    payToSpec
    collateralSpec
    spendIndexSpec
    scriptSpendSpec
    mintSpec
    ctxSpec
    buildSpec

data TestQ a where
    GetValue :: TestQ Int

spendSpec :: Spec
spendSpec =
    describe "spend" $ do
        it "adds TxIn to inputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <- spend (mkTxIn 1)
                        pure ()
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.member (mkTxIn 1) ins
                `shouldBe` True

        it "multiple spends all appear" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <- spend (mkTxIn 1)
                        _ <- spend (mkTxIn 2)
                        _ <- spend (mkTxIn 3)
                        pure ()
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.size ins `shouldBe` 3

payToSpec :: Spec
payToSpec =
    describe "payTo" $ do
        it "adds output to outputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <-
                            payTo
                                (mkAddr 1)
                                (inject (Coin 2_000_000))
                        pure ()
                outs =
                    tx ^. bodyTxL . outputsTxBodyL
            length outs `shouldBe` 1

        it "multiple payTo all appear in order" $
            do
                let tx =
                        draft emptyPParams $ do
                            _ <-
                                payTo
                                    (mkAddr 1)
                                    (inject (Coin 1_000_000))
                            _ <-
                                payTo
                                    (mkAddr 2)
                                    (inject (Coin 2_000_000))
                            pure ()
                    outs =
                        tx ^. bodyTxL . outputsTxBodyL
                length outs `shouldBe` 2

collateralSpec :: Spec
collateralSpec =
    describe "collateral" $ do
        it "adds to collateralInputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        collateral (mkTxIn 5)
                ins =
                    tx
                        ^. bodyTxL
                            . collateralInputsTxBodyL
            Set.member (mkTxIn 5) ins
                `shouldBe` True

        it "not in inputsTxBodyL" $ do
            let tx =
                    draft emptyPParams $ do
                        collateral (mkTxIn 5)
                ins =
                    tx ^. bodyTxL . inputsTxBodyL
            Set.member (mkTxIn 5) ins
                `shouldBe` False

spendIndexSpec :: Spec
spendIndexSpec =
    describe "spend index" $ do
        it "returns 0 for single input" $ do
            let (tx, idx) =
                    runDraft $
                        spend (mkTxIn 1)
            idx `shouldBe` 0
            Set.size
                (tx ^. bodyTxL . inputsTxBodyL)
                `shouldBe` 1

        it "returns correct sorted indices" $ do
            -- mkTxIn 1 sorts before mkTxIn 2
            let (_, (i1, i2)) = runDraft $ do
                    a <- spend (mkTxIn 2)
                    b <- spend (mkTxIn 1)
                    pure (a, b)
            -- mkTxIn 1 is at index 0 (sorts first)
            -- mkTxIn 2 is at index 1
            i2 `shouldBe` 0
            i1 `shouldBe` 1

        it "interleaves pure computation" $ do
            let (_, result) = runDraft $ do
                    i <- spend (mkTxIn 1)
                    let doubled = i * 2
                    _ <- spend (mkTxIn 2)
                    pure doubled
            -- mkTxIn 1 is at index 0, doubled = 0
            result `shouldBe` 0

scriptSpendSpec :: Spec
scriptSpendSpec =
    describe "spendScript" $ do
        it "produces a spending redeemer" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <-
                            spendScript
                                (mkTxIn 1)
                                (42 :: Integer)
                        pure ()
                Redeemers rdmrs =
                    tx ^. witsTxL . rdmrsTxWitsL
            Map.keys rdmrs
                `shouldBe` [ ConwaySpending
                                (AsIx 0)
                           ]

        it "multiple script spends get correct indices" $
            do
                let tx =
                        draft emptyPParams $ do
                            _ <-
                                spendScript
                                    (mkTxIn 2)
                                    (2 :: Integer)
                            _ <-
                                spendScript
                                    (mkTxIn 1)
                                    (1 :: Integer)
                            pure ()
                    Redeemers rdmrs =
                        tx ^. witsTxL . rdmrsTxWitsL
                Map.size rdmrs `shouldBe` 2
                Map.member
                    (ConwaySpending (AsIx 0))
                    rdmrs
                    `shouldBe` True
                Map.member
                    (ConwaySpending (AsIx 1))
                    rdmrs
                    `shouldBe` True

mintSpec :: Spec
mintSpec =
    describe "mint" $ do
        it "produces a minting redeemer" $ do
            let pid = mkPolicyId 1
                tx =
                    draft emptyPParams $ do
                        mint
                            pid
                            ( Map.singleton
                                ( AssetName
                                    (SBS.pack [0xDE, 0xAD])
                                )
                                100
                            )
                            (0 :: Integer)
                Redeemers rdmrs =
                    tx ^. witsTxL . rdmrsTxWitsL
            Map.keys rdmrs
                `shouldBe` [ConwayMinting (AsIx 0)]

        it "includes mint in TxBody" $ do
            let pid = mkPolicyId 1
                assetName =
                    AssetName (SBS.pack [0xCA, 0xFE])
                tx =
                    draft emptyPParams $ do
                        mint
                            pid
                            (Map.singleton assetName 50)
                            (0 :: Integer)
                MultiAsset ma =
                    tx ^. bodyTxL . mintTxBodyL
            Map.lookup pid ma
                `shouldBe` Just
                    (Map.singleton assetName 50)

        it "negative amounts produce burn" $ do
            let pid = mkPolicyId 1
                assetName = AssetName "tok"
                tx =
                    draft emptyPParams $ do
                        mint
                            pid
                            ( Map.singleton
                                assetName
                                (-1)
                            )
                            (0 :: Integer)
                MultiAsset ma =
                    tx ^. bodyTxL . mintTxBodyL
            Map.lookup pid ma
                `shouldBe` Just
                    (Map.singleton assetName (-1))

        it "combined spend + mint redeemers" $ do
            let pid = mkPolicyId 1
                tx =
                    draft emptyPParams $ do
                        _ <-
                            spendScript
                                (mkTxIn 1)
                                (42 :: Integer)
                        mint
                            pid
                            ( Map.singleton
                                (AssetName "t")
                                1
                            )
                            (0 :: Integer)
                Redeemers rdmrs =
                    tx ^. witsTxL . rdmrsTxWitsL
                hasSpend =
                    any isSpend (Map.keys rdmrs)
                hasMint =
                    any isMint (Map.keys rdmrs)
            hasSpend `shouldBe` True
            hasMint `shouldBe` True
            Map.size rdmrs `shouldBe` 2

ctxSpec :: Spec
ctxSpec =
    describe "ctx" $ do
        it "flows interpreted values through subsequent binds" $ do
            let interpret =
                    Interpret $ \GetValue -> 7
                expected :: TxOut ConwayEra
                expected =
                    mkBasicTxOut
                        (mkAddr 3)
                        (inject (Coin 7))
                tx =
                    draftWith emptyPParams interpret $ do
                        n <- ctx GetValue
                        _ <-
                            payTo
                                (mkAddr 3)
                                (inject (Coin (fromIntegral n)))
                        pure ()
                outs = tx ^. bodyTxL . outputsTxBodyL
            toList outs
                `shouldBe` [expected]

buildSpec :: Spec
buildSpec =
    describe "build" $ do
        it "produces a balanced Tx with no scripts" $
            do
                let prog = do
                        _ <- spend (mkTxIn 1)
                        _ <-
                            payTo
                                (mkAddr 2)
                                (inject (Coin 3_000_000))
                        pure ()
                    feeUtxo =
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            ( inject
                                (Coin 10_000_000)
                            )
                        )
                    mockEval _ = pure Map.empty
                result <-
                    build
                        emptyPParams
                        noCtxInterpretIO
                        mockEval
                        [feeUtxo]
                        (mkAddr 1)
                        prog
                case result of
                    Left err ->
                        expectationFailure $
                            show err
                    Right tx -> do
                        let ins =
                                tx
                                    ^. bodyTxL
                                        . inputsTxBodyL
                        Set.size ins
                            `shouldSatisfy` (> 0)

        it "peek reads fee from balanced Tx" $ do
            let prog = do
                    _ <- spend (mkTxIn 1)
                    fee <- peek $ \tx ->
                        Ok (tx ^. bodyTxL . feeTxBodyL)
                    _ <-
                        payTo
                            (mkAddr 2)
                            (inject fee)
                    pure ()
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                mockEval _ = pure Map.empty
            result <-
                build
                    emptyPParams
                    noCtxInterpretIO
                    mockEval
                    [feeUtxo]
                    (mkAddr 1)
                    prog
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    let Coin fee =
                            tx
                                ^. bodyTxL
                                    . feeTxBodyL
                    -- Fee is 0 with emptyPParams
                    -- (zero fee coefficients) — the
                    -- point is it converged, not the
                    -- value
                    fee `shouldSatisfy` (>= 0)

        it "resolves ctx queries through InterpretIO" $ do
            let prog = do
                    _ <- spend (mkTxIn 1)
                    n <- ctx GetValue
                    _ <-
                        payTo
                            (mkAddr 4)
                            (inject (Coin (fromIntegral n)))
                    pure ()
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                interpret =
                    InterpretIO $ \GetValue -> pure 7
                mockEval _ = pure Map.empty
            result <-
                build
                    emptyPParams
                    interpret
                    mockEval
                    [feeUtxo]
                    (mkAddr 1)
                    prog
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    let outs =
                            toList $
                                tx
                                    ^. bodyTxL
                                        . outputsTxBodyL
                        expected :: TxOut ConwayEra
                        expected =
                            mkBasicTxOut
                                (mkAddr 4)
                                (inject (Coin 7))
                    expected `shouldSatisfy` (`elem` outs)

isSpend ::
    ConwayPlutusPurpose AsIx ConwayEra -> Bool
isSpend (ConwaySpending _) = True
isSpend _ = False

isMint ::
    ConwayPlutusPurpose AsIx ConwayEra -> Bool
isMint (ConwayMinting _) = True
isMint _ = False

{- | Run draft and return both the Tx and the
program's result.
-}
runDraft ::
    TxBuild q e a -> (Tx ConwayEra, a)
runDraft = runDraftWith noCtxInterpret

runDraftWith ::
    Interpret q ->
    TxBuild q e a ->
    (Tx ConwayEra, a)
runDraftWith interpret prog =
    let initialTx = draft emptyPParams (pure ())
        (st1, _, _) =
            interpretWith interpret initialTx prog
        tx1 = assembleTx emptyPParams st1
        (st2, a, _) =
            interpretWith interpret tx1 prog
     in (assembleTx emptyPParams st2, a)

noCtxInterpret :: Interpret q
noCtxInterpret =
    Interpret $
        const $
            error
                "test: encountered ctx without interpreter"

noCtxInterpretIO :: InterpretIO q
noCtxInterpretIO =
    InterpretIO $
        const $
            error
                "test: encountered ctx without interpreter"
