{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.TxBuildSpec
Description : TxBuild DSL tests — Slice 1
License     : Apache-2.0

Tests for simple pub-key spend, payTo, collateral,
and draft assembly. Verifies inputs/outputs in
assembled Tx and that spend returns correct index.
-}
module Cardano.Node.Client.TxBuildSpec (spec) where

import Data.IORef (
    IORef,
    modifyIORef',
    newIORef,
    readIORef,
 )
import Data.Set qualified as Set
import Test.Hspec

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
    Withdrawals (..),
 )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (
    CoinPerByte (..),
    emptyPParams,
    ppCoinsPerUTxOByteL,
    ppMaxTxSizeL,
    ppTxFeeFixedL,
    ppTxFeePerByteL,
 )
import Cardano.Ledger.Api.Tx (
    auxDataTxL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    auxDataHashTxBodyL,
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    StrictMaybe (SJust),
    TxIx (..),
 )
import Cardano.Ledger.Coin (
    Coin (..),
    compactCoinOrError,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (
    bodyTxL,
    hashTxAuxData,
    metadataTxAuxDataL,
    mkBasicTxAuxData,
 )
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (
    ScriptHash (..),
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Guard),
 )
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Ledger.TxIn (
    TxId (..),
    TxIn (..),
 )
import Cardano.Node.Client.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild
import Cardano.Slotting.Slot (SlotNo (..))
import Lens.Micro ((&), (.~), (^.))

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

mkWitnessKeyHash :: Word8 -> KeyHash Guard
mkWitnessKeyHash n =
    KeyHash (mkHash28 n)

mkRewardAccount :: Word8 -> AccountAddress
mkRewardAccount n =
    AccountAddress
        Testnet
        (AccountId (KeyHashObj (KeyHash (mkHash28 n))))

mkScriptRewardAccount :: Word8 -> AccountAddress
mkScriptRewardAccount n =
    AccountAddress
        Testnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

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
    withdrawSpec
    metadataSpec
    ctxSpec
    validSpec
    referenceValiditySpec
    buildSpec

data TestQ a where
    GetValue :: TestQ Int
    RecordFee :: Coin -> TestQ ()

data TestErr
    = BrokenInvariant
    deriving (Show, Eq)

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

withdrawSpec :: Spec
withdrawSpec =
    describe "withdraw" $ do
        it "adds pub-key withdrawals to the tx body" $ do
            let rewardAccount = mkRewardAccount 7
                tx =
                    draft emptyPParams $
                        withdraw rewardAccount (Coin 3_000_000)
                Redeemers rdmrs =
                    tx ^. witsTxL . rdmrsTxWitsL
            tx ^. bodyTxL . withdrawalsTxBodyL
                `shouldBe` Withdrawals
                    (Map.singleton rewardAccount (Coin 3_000_000))
            Map.null rdmrs `shouldBe` True

        it "produces rewarding redeemers for script withdrawals" $ do
            let rewardAccount = mkScriptRewardAccount 8
                tx =
                    draft emptyPParams $
                        withdrawScript
                            rewardAccount
                            (Coin 2_000_000)
                            (99 :: Integer)
                Redeemers rdmrs =
                    tx ^. witsTxL . rdmrsTxWitsL
            tx ^. bodyTxL . withdrawalsTxBodyL
                `shouldBe` Withdrawals
                    (Map.singleton rewardAccount (Coin 2_000_000))
            Map.keys rdmrs
                `shouldBe` [ConwayRewarding (AsIx 0)]

metadataSpec :: Spec
metadataSpec =
    describe "setMetadata" $ do
        it "attaches auxiliary data and hashes it in the tx body" $ do
            let tx =
                    draft emptyPParams $
                        setMetadata 674 (S "gm")
                expectedAux =
                    mkBasicTxAuxData
                        & metadataTxAuxDataL
                            .~ Map.singleton 674 (S "gm")
            case tx ^. auxDataTxL of
                SJust aux -> do
                    aux `shouldBe` expectedAux
                    tx ^. bodyTxL . auxDataHashTxBodyL
                        `shouldBe` SJust (hashTxAuxData aux)
                _ ->
                    expectationFailure
                        "expected auxiliary data"

        it "keeps the last value written for a metadata label" $ do
            let tx =
                    draft emptyPParams $ do
                        setMetadata 674 (S "first")
                        setMetadata 674 (S "second")
                expectedAux =
                    mkBasicTxAuxData
                        & metadataTxAuxDataL
                            .~ Map.singleton 674 (S "second")
            case tx ^. auxDataTxL of
                SJust aux ->
                    aux `shouldBe` expectedAux
                _ ->
                    expectationFailure
                        "expected auxiliary data"

ctxSpec :: Spec
ctxSpec =
    describe "ctx" $ do
        it "flows interpreted values through subsequent binds" $ do
            let interpret =
                    Interpret $ \case
                        GetValue -> 7
                        RecordFee _ -> ()
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

validSpec :: Spec
validSpec =
    describe "valid" $ do
        it "returns custom failures after convergence" $ do
            let prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- spend (mkTxIn 1)
                    valid $
                        const $
                            CustomFail BrokenInvariant
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
                    []
                    (mkAddr 1)
                    prog
            case result of
                Left (ChecksFailed [CustomFail err]) ->
                    err `shouldBe` BrokenInvariant
                Left err ->
                    expectationFailure $ show err
                Right _ ->
                    expectationFailure
                        "expected custom validation failure"

        it "fails checkMinUtxo when an output is below the threshold" $
            do
                let pp =
                        emptyPParams @ConwayEra
                            & ppCoinsPerUTxOByteL
                                .~ CoinPerByte
                                    (compactCoinOrError (Coin 1))
                    prog :: TxBuild TestQ TestErr ()
                    prog = do
                        _ <- spend (mkTxIn 1)
                        outIx <-
                            payTo
                                (mkAddr 2)
                                (inject (Coin 1))
                        checkMinUtxo pp outIx
                    feeUtxo =
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            (inject (Coin 10_000_000))
                        )
                    mockEval _ = pure Map.empty
                result <-
                    build
                        pp
                        noCtxInterpretIO
                        mockEval
                        [feeUtxo]
                        []
                        (mkAddr 1)
                        prog
                case result of
                    Left
                        ( ChecksFailed
                                [ LedgerFail
                                        (MinUtxoViolation ix actual required)
                                    ]
                            ) -> do
                            ix `shouldBe` 0
                            actual `shouldBe` Coin 1
                            actual `shouldSatisfy` (< required)
                    Left err ->
                        expectationFailure $ show err
                    Right _ ->
                        expectationFailure
                            "expected min-UTxO failure"

        it "fails checkTxSize when the encoded tx exceeds ppMaxTxSizeL" $
            do
                let pp =
                        emptyPParams
                            & ppMaxTxSizeL .~ 1
                    prog :: TxBuild TestQ TestErr ()
                    prog = do
                        _ <- spend (mkTxIn 1)
                        _ <-
                            payTo
                                (mkAddr 2)
                                (inject (Coin 3_000_000))
                        checkTxSize pp
                    feeUtxo =
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            (inject (Coin 10_000_000))
                        )
                    mockEval _ = pure Map.empty
                result <-
                    build
                        pp
                        noCtxInterpretIO
                        mockEval
                        [feeUtxo]
                        []
                        (mkAddr 1)
                        prog
                case result of
                    Left
                        ( ChecksFailed
                                [ LedgerFail
                                        (TxSizeExceeded actual limit)
                                    ]
                            ) -> do
                            limit `shouldBe` 1
                            actual `shouldSatisfy` (> limit)
                    Left err ->
                        expectationFailure $ show err
                    Right _ ->
                        expectationFailure
                            "expected tx-size failure"

        it "returns Right when all checks pass" $ do
            let pp =
                    emptyPParams
                        & ppCoinsPerUTxOByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 1))
                prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- spend (mkTxIn 1)
                    outIx <-
                        payTo
                            (mkAddr 2)
                            (inject (Coin 5_000_000))
                    checkMinUtxo pp outIx
                    valid $ const Pass
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                mockEval _ = pure Map.empty
            result <-
                build
                    pp
                    noCtxInterpretIO
                    mockEval
                    [feeUtxo]
                    []
                    (mkAddr 1)
                    prog
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    let outs =
                            tx ^. bodyTxL . outputsTxBodyL
                    length outs
                        `shouldSatisfy` (> 0)

referenceValiditySpec :: Spec
referenceValiditySpec =
    describe "reference inputs and validity interval" $ do
        it "assembles retract-shaped body fields" $ do
            let signer = mkWitnessKeyHash 9
                lower = SlotNo 10
                upper = SlotNo 20
                tx =
                    draft emptyPParams $ do
                        _ <- spend (mkTxIn 1)
                        reference (mkTxIn 2)
                        requireSignature signer
                        validFrom lower
                        validTo upper
                        pure ()
                body = tx ^. bodyTxL
            body ^. referenceInputsTxBodyL
                `shouldBe` Set.singleton (mkTxIn 2)
            body ^. inputsTxBodyL
                `shouldBe` Set.singleton (mkTxIn 1)
            body ^. reqSignerHashesTxBodyL
                `shouldBe` Set.singleton signer
            body ^. vldtTxBodyL
                `shouldBe` ValidityInterval
                    { invalidBefore = SJust lower
                    , invalidHereafter = SJust upper
                    }

buildSpec :: Spec
buildSpec =
    describe "build" $ do
        it "produces a balanced Tx with no scripts" $
            do
                let prog :: TxBuild TestQ TestErr ()
                    prog = do
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
                        []
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
            let prog :: TxBuild TestQ TestErr ()
                prog = do
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
                    []
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
            let prog :: TxBuild TestQ TestErr ()
                prog = do
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
                    InterpretIO $ \case
                        GetValue -> pure 7
                        RecordFee _ -> pure ()
                mockEval _ = pure Map.empty
            result <-
                build
                    emptyPParams
                    interpret
                    mockEval
                    [feeUtxo]
                    []
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

        it
            "fee-dependent outputs converge \
            \(conservation equation)"
            $ do
                -- Simulate a conservation-aware
                -- validator: the mock evaluator
                -- checks that fee + outputs == inputs.
                -- Refund = inputVal - tip - fee.
                -- Tip is fixed, fee is what Peek reads.
                let pp =
                        emptyPParams @ConwayEra
                            & ppMaxTxSizeL .~ 16384
                            & ppTxFeePerByteL
                                .~ CoinPerByte
                                    (compactCoinOrError (Coin 44))
                            & ppTxFeeFixedL .~ Coin 155381
                            & ppCoinsPerUTxOByteL
                                .~ CoinPerByte
                                    (compactCoinOrError (Coin 4310))
                    tip = 1_000_000
                    inputVal = 5_000_000
                    scriptUtxo =
                        ( mkTxIn 2
                        , mkBasicTxOut
                            (mkAddr 3)
                            (inject (Coin inputVal))
                        )
                    feeUtxo =
                        ( mkTxIn 1
                        , mkBasicTxOut
                            (mkAddr 1)
                            ( inject
                                (Coin 10_000_000)
                            )
                        )
                    prog ::
                        TxBuild TestQ TestErr ()
                    prog = do
                        _ <-
                            spendScript
                                (mkTxIn 2)
                                (42 :: Integer)
                        Coin fee <- peek $ \tx ->
                            let f =
                                    tx
                                        ^. bodyTxL
                                            . feeTxBodyL
                             in if f > Coin 0
                                    then Ok f
                                    else Iterate f
                        let refund =
                                inputVal - tip - fee
                        _ <-
                            payTo
                                (mkAddr 4)
                                (inject (Coin refund))
                        collateral (mkTxIn 1)
                        pure ()
                    -- Mock evaluator: check
                    -- conservation equation.
                    -- Only the first output (refund)
                    -- participates; the change output
                    -- (added by balanceTx) is ignored.
                    mockEval tx =
                        let Coin fee =
                                tx
                                    ^. bodyTxL
                                        . feeTxBodyL
                            outs =
                                toList
                                    ( tx
                                        ^. bodyTxL
                                            . outputsTxBodyL
                                    )
                            -- First output is the
                            -- refund (from Peek).
                            refund = case outs of
                                (o : _) ->
                                    let Coin c =
                                            o
                                                ^. coinTxOutL
                                     in c
                                [] -> 0
                         in if fee + refund + tip
                                == inputVal
                                then
                                    pure
                                        ( Map.singleton
                                            ( ConwaySpending
                                                (AsIx 0)
                                            )
                                            ( Right
                                                ( ExUnits
                                                    100
                                                    100
                                                )
                                            )
                                        )
                                else
                                    pure
                                        ( Map.singleton
                                            ( ConwaySpending
                                                (AsIx 0)
                                            )
                                            ( Left
                                                ( "conservation \
                                                  \violated: fee="
                                                    <> show fee
                                                    <> " refund="
                                                    <> show refund
                                                    <> " tip="
                                                    <> show tip
                                                    <> " sum="
                                                    <> show
                                                        ( fee
                                                            + refund
                                                            + tip
                                                        )
                                                    <> " expected="
                                                    <> show inputVal
                                                )
                                            )
                                        )
                result <-
                    build
                        pp
                        noCtxInterpretIO
                        mockEval
                        [ feeUtxo
                        , scriptUtxo
                        ]
                        []
                        (mkAddr 1)
                        prog
                case result of
                    Left err ->
                        expectationFailure $
                            show err
                    Right tx -> do
                        let Coin fee =
                                tx
                                    ^. bodyTxL
                                        . feeTxBodyL
                        -- Conservation holds in
                        -- the final tx
                        fee
                            `shouldSatisfy` (> 0)

        it "retries with an estimated fee after eval failure" $ do
            feeHistoryRef <- newIORef []
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 44))
                        & ppTxFeeFixedL .~ Coin 155381
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                spendUtxo =
                    ( mkTxIn 2
                    , mkBasicTxOut
                        (mkAddr 3)
                        (inject (Coin 5_000_000))
                    )
                prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- spend (mkTxIn 2)
                    fee <- peek $ \tx ->
                        Ok (tx ^. bodyTxL . feeTxBodyL)
                    _ <- ctx (RecordFee fee)
                    _ <-
                        payTo
                            (mkAddr 4)
                            (inject fee)
                    pure ()
                interpret =
                    recordingInterpret feeHistoryRef
                mockEval tx =
                    pure $
                        if tx ^. bodyTxL . feeTxBodyL
                            == Coin 0
                            then
                                Map.singleton
                                    (ConwaySpending (AsIx 0))
                                    (Left "fee too small")
                            else Map.empty
            result <-
                build
                    pp
                    interpret
                    mockEval
                    [feeUtxo, spendUtxo]
                    []
                    (mkAddr 1)
                    prog
            history <- readRecordedFees feeHistoryRef
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    history `shouldSatisfy` elem (Coin 0)
                    history
                        `shouldSatisfy` any (> Coin 0)
                    last history
                        `shouldBe` (tx ^. bodyTxL . feeTxBodyL)

        it "surfaces terminal eval failure instead of retrying" $ do
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 44))
                        & ppTxFeeFixedL .~ Coin 155381
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                spendUtxo =
                    ( mkTxIn 2
                    , mkBasicTxOut
                        (mkAddr 3)
                        (inject (Coin 5_000_000))
                    )
                prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- spend (mkTxIn 2)
                    pure ()
                interpret = InterpretIO (const (pure undefined))
                -- Evaluator always fails regardless
                -- of fee — a genuine script bug.
                mockEval _tx =
                    pure $
                        Map.singleton
                            (ConwaySpending (AsIx 0))
                            (Left "script logic error")
            result <-
                build
                    pp
                    interpret
                    mockEval
                    [feeUtxo, spendUtxo]
                    []
                    (mkAddr 1)
                    prog
            case result of
                Left (EvalFailure _purpose msg) ->
                    msg `shouldBe` "script logic error"
                Left other ->
                    expectationFailure $
                        "expected EvalFailure, got: "
                            <> show other
                Right _ ->
                    expectationFailure
                        "expected EvalFailure, got Right"

        it "re-iterates when Peek has not converged" $ do
            -- Peek returns Iterate on the first pass,
            -- Ok on the second. The build loop must
            -- not stop after the first fee convergence.
            passRef <- newIORef (0 :: Int)
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 44))
                        & ppTxFeeFixedL .~ Coin 155381
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 10_000_000))
                    )
                prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- peek $ \tx -> do
                        let Coin f =
                                tx
                                    ^. bodyTxL
                                        . feeTxBodyL
                        if f > 0
                            then Ok (Coin f)
                            else Iterate (Coin 0)
                    pure ()
                interpret =
                    InterpretIO $ \case
                        RecordFee _ -> do
                            modifyIORef' passRef (+ 1)
                            pure ()
                        GetValue ->
                            pure 0
                mockEval _tx = pure Map.empty
            result <-
                build
                    pp
                    interpret
                    mockEval
                    [feeUtxo]
                    []
                    (mkAddr 1)
                    prog
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    let Coin fee =
                            tx
                                ^. bodyTxL . feeTxBodyL
                    fee `shouldSatisfy` (> 0)

        it "re-interprets outputs after a fee oscillation" $ do
            feeHistoryRef <- newIORef []
            let pp =
                    emptyPParams @ConwayEra
                        & ppTxFeePerByteL
                            .~ CoinPerByte
                                (compactCoinOrError (Coin 10))
                        & ppTxFeeFixedL .~ Coin 0
                        & ppMaxTxSizeL .~ 100_000
                feeUtxo =
                    ( mkTxIn 1
                    , mkBasicTxOut
                        (mkAddr 1)
                        (inject (Coin 20_000_000))
                    )
                spendUtxo =
                    ( mkTxIn 2
                    , mkBasicTxOut
                        (mkAddr 3)
                        (inject (Coin 5_000_000))
                    )
                inputUtxos = [feeUtxo, spendUtxo]
                smallCoin = Coin 3_000_000
                largeCoin = Coin 4_000_000
                smallDatum = ([] :: [Integer])
                largeDatum = [1 .. 2000] :: [Integer]
                feeFor datum coin =
                    case balanceTx
                        pp
                        inputUtxos
                        []
                        (mkAddr 1)
                        ( draft pp $ do
                            _ <- spend (mkTxIn 2)
                            _ <-
                                payTo'
                                    (mkAddr 4)
                                    (inject coin)
                                    datum
                            pure ()
                        ) of
                        Left err ->
                            expectationFailure (show err)
                                >> pure (Coin 0)
                        Right BalanceResult{balancedTx = tx} ->
                            pure $
                                tx
                                    ^. bodyTxL
                                        . feeTxBodyL
            lowFee <- feeFor smallDatum smallCoin
            highFee <- feeFor largeDatum largeCoin
            let Coin lo = min lowFee highFee
                Coin hi = max lowFee highFee
                pivot = Coin (lo + (hi - lo) `div` 2)
                prog :: TxBuild TestQ TestErr ()
                prog = do
                    _ <- spend (mkTxIn 2)
                    fee <- peek $ \tx ->
                        Ok (tx ^. bodyTxL . feeTxBodyL)
                    _ <- ctx (RecordFee fee)
                    if fee < pivot
                        then do
                            _ <-
                                payTo'
                                    (mkAddr 4)
                                    (inject largeCoin)
                                    largeDatum
                            pure ()
                        else do
                            _ <-
                                payTo'
                                    (mkAddr 4)
                                    (inject smallCoin)
                                    smallDatum
                            pure ()
                interpret =
                    recordingInterpret feeHistoryRef
                mockEval _ = pure Map.empty
            max lowFee highFee
                `shouldSatisfy` (> min lowFee highFee)
            result <-
                build
                    pp
                    interpret
                    mockEval
                    inputUtxos
                    []
                    (mkAddr 1)
                    prog
            history <- readRecordedFees feeHistoryRef
            case result of
                Left err ->
                    expectationFailure $ show err
                Right tx -> do
                    let finalFee =
                            tx
                                ^. bodyTxL
                                    . feeTxBodyL
                        outs =
                            toList $
                                tx
                                    ^. bodyTxL
                                        . outputsTxBodyL
                        firstOut =
                            case outs of
                                o : _ -> o
                                [] ->
                                    error
                                        "expected at least one output"
                    history
                        `shouldSatisfy` any (< pivot)
                    history
                        `shouldSatisfy` any (>= pivot)
                    last history `shouldBe` finalFee
                    if finalFee < pivot
                        then
                            firstOut ^. coinTxOutL
                                `shouldBe` largeCoin
                        else
                            firstOut ^. coinTxOutL
                                `shouldBe` smallCoin

        it "bumpFee only shrinks the change output" $ do
            let tx =
                    draft emptyPParams $ do
                        _ <-
                            payTo
                                (mkAddr 2)
                                (inject (Coin 3_000_000))
                        _ <-
                            payTo
                                (mkAddr 1)
                                (inject (Coin 7_000_000))
                        pure ()
                bumped =
                    bumpFee
                        1
                        (tx & bodyTxL . feeTxBodyL .~ Coin 200)
                        (Coin 500)
                outs =
                    case bumped of
                        Left err ->
                            error err
                        Right tx' ->
                            toList $
                                tx'
                                    ^. bodyTxL
                                        . outputsTxBodyL
            case bumped of
                Left err ->
                    expectationFailure err
                Right tx' -> do
                    tx' ^. bodyTxL . feeTxBodyL
                        `shouldBe` Coin 500
                    map (^. coinTxOutL) outs
                        `shouldBe` [ Coin 3_000_000
                                   , Coin 6_999_700
                                   ]

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
    TxBuild q e a -> (ConwayTx, a)
runDraft = runDraftWith noCtxInterpret

runDraftWith ::
    Interpret q ->
    TxBuild q e a ->
    (ConwayTx, a)
runDraftWith interpret prog =
    let initialTx = draft (emptyPParams @ConwayEra) (pure ())
        (st1, _, _) =
            interpretWith interpret initialTx prog
        tx1 = assembleTx (emptyPParams @ConwayEra) st1
        (st2, a, _) =
            interpretWith interpret tx1 prog
     in (assembleTx (emptyPParams @ConwayEra) st2, a)

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

recordingInterpret ::
    IORef [Coin] -> InterpretIO TestQ
recordingInterpret feeHistoryRef =
    InterpretIO $ \case
        GetValue -> pure 7
        RecordFee fee ->
            modifyIORef' feeHistoryRef (fee :)

readRecordedFees :: IORef [Coin] -> IO [Coin]
readRecordedFees feeHistoryRef =
    reverse <$> readIORef feeHistoryRef
