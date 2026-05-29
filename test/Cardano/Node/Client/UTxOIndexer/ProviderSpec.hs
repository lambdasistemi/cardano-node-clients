{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

module Cardano.Node.Client.UTxOIndexer.ProviderSpec (spec) where

import Cardano.Chain.Common qualified as ByronCommon
import Cardano.Crypto.Hash.Class (Hash (..))
import Cardano.Ledger.Address (
    Addr (..),
    BootstrapAddress (..),
    serialiseAddr,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Binary qualified as LedgerBinary
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.Provider qualified as LedgerProvider
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    withInMemoryIndexerRunner,
 )
import Cardano.Node.Client.UTxOIndexer.Provider (
    Provider (..),
    ProviderSingleton (..),
    queryIndexedUTxOByTxIn,
    queryIndexedUTxOs,
    queryIndexedUTxOsAt,
    queryLedgerSnapshotL,
    queryLedgerSnapshotLH,
    withAcquiredLedger,
    withProvider,
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Slotting.Slot (EpochNo (..), SlotNo (..))
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.KV.Transaction (
    RunTransaction (..),
 )
import Database.KV.Transaction qualified as KV
import Ouroboros.Network.Block (pattern GenesisPoint)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer.Provider" $ do
        it "opens the CLI ledger-only provider without an indexer" $ do
            (directEra, acquiredEra) <-
                withProvider
                    (SLedgerOnly failingUtxoLedgerProvider)
                    $ \case
                        LedgerOnlyProvider ledger -> do
                            direct <- queryLedgerSnapshotL ledger
                            acquired <-
                                withAcquiredLedger
                                    ledger
                                    queryLedgerSnapshotLH
                            pure
                                ( LedgerProvider.ledgerCurrentEra direct
                                , LedgerProvider.ledgerCurrentEra acquired
                                )

            directEra `shouldBe` Text.pack "Conway"
            acquiredEra `shouldBe` Text.pack "Conway"

        it "opens acquired ledger and indexer transaction scopes together" $
            withIndexedOutput $ \runner txIn txOut -> do
                (rows, byAddr, byTxIn, directEra, acquiredEra) <-
                    withProvider
                        (SLedgerAndIndexer failingUtxoLedgerProvider runner)
                        $ \case
                            LedgerAndIndexerProvider ledger indexer -> do
                                direct <- queryLedgerSnapshotL ledger
                                acquired <-
                                    withAcquiredLedger
                                        ledger
                                        queryLedgerSnapshotLH
                                (,,,,)
                                    <$> queryIndexedUTxOs
                                        indexer
                                        testAddr
                                    <*> queryIndexedUTxOsAt
                                        indexer
                                        (Set.singleton testAddr)
                                    <*> queryIndexedUTxOByTxIn
                                        indexer
                                        (Set.singleton txIn)
                                    <*> pure
                                        ( LedgerProvider.ledgerCurrentEra
                                            direct
                                        )
                                    <*> pure
                                        ( LedgerProvider.ledgerCurrentEra
                                            acquired
                                        )

                rows `shouldBe` [(txIn, txOut)]
                byAddr
                    `shouldBe` Map.singleton
                        testAddr
                        [(txIn, txOut)]
                byTxIn `shouldBe` Map.singleton txIn txOut
                directEra `shouldBe` Text.pack "Conway"
                acquiredEra `shouldBe` Text.pack "Conway"

withIndexedOutput ::
    ( forall cf op.
      RunTransaction IO cf Cols op ->
      Ledger.TxIn ->
      TxOut ConwayEra ->
      IO a
    ) ->
    IO a
withIndexedOutput action = do
    withInMemoryIndexerRunner $ \_handle runner@RunTransaction{runTransaction} -> do
        runTransaction $ do
            KV.insert TxInCol testIndexerTxIn indexedAddr
            KV.insert
                AddressIndex
                (Indexer.AddrKey indexedAddr testIndexerTxIn)
                (Indexer.TxOut (serialize' conwayVersion testTxOut))
        action runner testLedgerTxIn testTxOut

failingUtxoLedgerProvider :: LedgerProvider.Provider IO
failingUtxoLedgerProvider =
    LedgerProvider.Provider
        { LedgerProvider.withAcquired = \callback ->
            callback $
                LedgerProvider.mkQueryHandle
                    LedgerProvider.QueryHandleBackend
                        { LedgerProvider.backendQueryUTxOs =
                            \_ -> failIO "base provider queryUTxOs used"
                        , LedgerProvider.backendQueryUTxOsAt =
                            \_ -> failIO "base provider queryUTxOsAt used"
                        , LedgerProvider.backendQueryUTxOByTxIn =
                            \_ ->
                                failIO
                                    "base provider queryUTxOByTxIn used"
                        , LedgerProvider.backendQueryProtocolParams =
                            failIO "unused queryProtocolParams"
                        , LedgerProvider.backendQueryLedgerSnapshot =
                            pure testLedgerSnapshot
                        , LedgerProvider.backendQueryStakeRewards =
                            \_ -> failIO "unused queryStakeRewards"
                        , LedgerProvider.backendQueryRewardAccounts =
                            \_ -> failIO "unused queryRewardAccounts"
                        , LedgerProvider.backendQueryVoteDelegatees =
                            \_ -> failIO "unused queryVoteDelegatees"
                        , LedgerProvider.backendQueryTreasury =
                            failIO "unused queryTreasury"
                        , LedgerProvider.backendQueryGovernanceState =
                            failIO "unused queryGovernanceState"
                        , LedgerProvider.backendEvaluateTx =
                            \_ -> failIO "unused evaluateTx"
                        , LedgerProvider.backendPosixMsToSlot =
                            \_ -> failIO "unused posixMsToSlot"
                        , LedgerProvider.backendPosixMsCeilSlot =
                            \_ -> failIO "unused posixMsCeilSlot"
                        }
        , LedgerProvider.queryUTxOs =
            \_ -> failIO "base provider queryUTxOs used"
        , LedgerProvider.queryUTxOByTxIn =
            \_ -> failIO "base provider queryUTxOByTxIn used"
        , LedgerProvider.queryProtocolParams =
            failIO "unused queryProtocolParams"
        , LedgerProvider.queryLedgerSnapshot = pure testLedgerSnapshot
        , LedgerProvider.queryStakeRewards =
            \_ -> failIO "unused queryStakeRewards"
        , LedgerProvider.queryRewardAccounts =
            \_ -> failIO "unused queryRewardAccounts"
        , LedgerProvider.queryVoteDelegatees =
            \_ -> failIO "unused queryVoteDelegatees"
        , LedgerProvider.queryTreasury = failIO "unused queryTreasury"
        , LedgerProvider.queryGovernanceState =
            failIO "unused queryGovernanceState"
        , LedgerProvider.evaluateTx = \_ -> failIO "unused evaluateTx"
        , LedgerProvider.posixMsToSlot =
            \_ -> failIO "unused posixMsToSlot"
        , LedgerProvider.posixMsCeilSlot =
            \_ -> failIO "unused posixMsCeilSlot"
        , LedgerProvider.queryUpperBoundSlot =
            \_ -> failIO "unused queryUpperBoundSlot"
        }

failIO :: String -> IO a
failIO = ioError . userError

testLedgerSnapshot :: LedgerProvider.LedgerSnapshot
testLedgerSnapshot =
    LedgerProvider.LedgerSnapshot
        { LedgerProvider.ledgerCurrentEra = Text.pack "Conway"
        , LedgerProvider.ledgerChainPoint = GenesisPoint
        , LedgerProvider.ledgerTipSlot = SlotNo 44
        , LedgerProvider.ledgerEpoch = EpochNo 2
        }

testIndexerTxIn :: Indexer.TxIn
testIndexerTxIn =
    Indexer.TxIn
        { Indexer.txInId = testTxIdBytes
        , Indexer.txInIx = 3
        }

testLedgerTxIn :: Ledger.TxIn
testLedgerTxIn =
    Ledger.TxIn
        ( Ledger.TxId
            (unsafeMakeSafeHash (UnsafeHash (SBS.toShort testTxIdBytes)))
        )
        (TxIx 3)

testTxIdBytes :: BS.ByteString
testTxIdBytes = BS.replicate 32 0x11

indexedAddr :: Indexer.Address
indexedAddr = Indexer.Address (serialiseAddr testAddr)

testAddr :: Addr
testAddr = AddrBootstrap (BootstrapAddress byronAddress)

testTxOut :: TxOut ConwayEra
testTxOut =
    mkBasicTxOut @ConwayEra
        testAddr
        (inject $ Coin 42_000_000)

byronAddress :: ByronCommon.Address
byronAddress =
    either
        (error . show)
        id
        ( ByronCommon.decodeAddressBase58
            "DdzFFzCqrhsq3KjLtT51mESbZ4RepiHPzLqEhamexVFTJpGbCXmh7qSxnHvaL88QmtVTD1E1sjx8Z1ZNDhYmcBV38ZjDST9kYVxSkhcw"
        )

conwayVersion :: LedgerBinary.Version
conwayVersion = eraProtVerLow @ConwayEra
