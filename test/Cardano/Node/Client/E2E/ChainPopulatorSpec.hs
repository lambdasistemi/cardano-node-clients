{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.E2E.ChainPopulatorSpec
Description : E2E test for the chain populator
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.ChainPopulatorSpec (spec) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn, mkTxInPartial)
import Cardano.Node.Client.Balance (BalanceResult (..), balanceTx)
import Cardano.Node.Client.E2E.ChainPopulator (
    ChainPopulator (..),
    PopulatorNext (..),
    populateChain,
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    devnetMagic,
    genesisAddr,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Types (Block)
import Cardano.Read.Ledger.Block.Block (fromConsensusBlock)
import Cardano.Read.Ledger.Block.Txs (getEraTransactions)
import Cardano.Read.Ledger.Eras.EraValue (applyEraFun)
import Cardano.Read.Ledger.Tx.Hash (getEraTxHash)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (elemIndex)
import Lens.Micro ((^.))
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

-- | Extract all tx hashes from a block.
blockTxHashes :: Block -> [ByteString]
blockTxHashes =
    applyEraFun
        (map getEraTxHash . getEraTransactions)
        . fromConsensusBlock

-- | Extract raw hash bytes from a TxId.
txIdBytes :: TxId -> ByteString
txIdBytes (TxId safeHash) =
    hashToBytes (extractHash safeHash)

-- | Get change output (last output) as (TxIn, TxOut).
changeOutput ::
    ConwayTx -> (TxIn, TxOut ConwayEra)
changeOutput tx =
    let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
        lastIdx = length outs - 1
     in ( mkTxInPartial (txIdTx tx) (fromIntegral lastIdx)
        , last outs
        )

{- | Build a chain of N self-transfer txs from an
initial UTxO. Each tx spends the change output
of the previous one.
-}
buildTxChain ::
    PParams ConwayEra ->
    (TxIn, TxOut ConwayEra) ->
    Int ->
    ( [ConwayTx]
    , (TxIn, TxOut ConwayEra)
    )
buildTxChain _ utxo 0 = ([], utxo)
buildTxChain pp utxo n =
    case balanceTx
        pp
        [utxo]
        []
        genesisAddr
        (mkBasicTx mkBasicTxBody) of
        Left err ->
            error $ "buildTxChain: " <> show err
        Right BalanceResult{balancedTx = tx} ->
            let (rest, finalUtxo) =
                    buildTxChain pp (changeOutput tx) (n - 1)
             in (tx : rest, finalUtxo)

spec :: Spec
spec =
    describe "ChainPopulator" $ do
        it "returns blocks from the chain" $ do
            gDir <- genesisDir
            blocksRef <- newIORef ([] :: [Block])

            withCardanoNode gDir $ \socketPath _startMs ->
                populateChain
                    socketPath
                    devnetMagic
                    genesisAddr
                    genesisSignKey
                    $ \_ _ -> followN blocksRef 10

            blocks <- readIORef blocksRef
            length blocks `shouldSatisfy` (>= 10)

        it "batch of chained txs appear in order" $ do
            gDir <- genesisDir
            submittedRef <- newIORef ([] :: [TxId])
            blocksRef <- newIORef ([] :: [Block])

            withCardanoNode gDir $ \socketPath _startMs ->
                populateChain
                    socketPath
                    devnetMagic
                    genesisAddr
                    genesisSignKey
                    $ \pp utxos ->
                        case utxos of
                            [] -> error "no initial UTxOs"
                            (u : _) ->
                                submitBatches
                                    submittedRef
                                    blocksRef
                                    pp
                                    u
                                    10

            submitted <- readIORef submittedRef
            blocks <- readIORef blocksRef
            -- All 100 txs submitted
            length submitted `shouldBe` 100

            -- All appear in blocks
            let allTxHashes =
                    concatMap blockTxHashes blocks
                submittedBytes =
                    map txIdBytes submitted

            mapM_
                ( \h ->
                    h `elem` allTxHashes
                        `shouldBe` True
                )
                submittedBytes

            -- Order preserved
            let indices =
                    map
                        (`elemIndex` allTxHashes)
                        submittedBytes
            indices `shouldSatisfy` isAscending
  where
    isAscending [] = True
    isAscending [_] = True
    isAscending (Just a : Just b : rest) =
        a < b && isAscending (Just b : rest)
    isAscending _ = False

{- | Follow N blocks then close, delivering
accumulated blocks to the IORef.
-}
followN ::
    IORef [Block] ->
    Int ->
    ChainPopulator
followN ref 0 =
    ChainPopulator $ \_ _ ->
        pure $
            Close [] $ \case
                Right blocks ->
                    modifyIORef' ref (const blocks)
                Left err ->
                    error $ "followN: " <> show err
followN ref n =
    ChainPopulator $ \_ _ ->
        pure $ Continue [] $ followN ref (n - 1)

{- | Submit batches of 10 chained txs, 10 times.
Wait 3 blocks between batches.
-}
submitBatches ::
    IORef [TxId] ->
    IORef [Block] ->
    PParams ConwayEra ->
    (TxIn, TxOut ConwayEra) ->
    Int ->
    ChainPopulator
submitBatches _submitted blocksRef _ _ 0 =
    followAndClose blocksRef 200
submitBatches submitted blocksRef pp utxo n =
    ChainPopulator $ \_ _block -> do
        let batchSize = 10
            (txs, nextUtxo) =
                buildTxChain pp utxo batchSize
        modifyIORef'
            submitted
            (++ map txIdTx txs)
        pure $
            Continue txs $
                waitBlocks
                    3
                    ( submitBatches
                        submitted
                        blocksRef
                        pp
                        nextUtxo
                        (n - 1)
                    )

-- | Follow N blocks then close with the blocks.
followAndClose ::
    IORef [Block] ->
    Int ->
    ChainPopulator
followAndClose ref 0 =
    ChainPopulator $ \_ _ ->
        pure $
            Close [] $ \case
                Right blocks ->
                    modifyIORef' ref (const blocks)
                Left err ->
                    error $ "followAndClose: " <> show err
followAndClose ref n =
    ChainPopulator $ \_ _ ->
        pure $ Continue [] $ followAndClose ref (n - 1)

-- | Skip N blocks without submitting.
waitBlocks :: Int -> ChainPopulator -> ChainPopulator
waitBlocks 0 next = next
waitBlocks n next =
    ChainPopulator $ \_ _ ->
        pure $ Continue [] $ waitBlocks (n - 1) next
