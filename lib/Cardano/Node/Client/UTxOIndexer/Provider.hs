{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.Provider
Description : Typed provider modes for ledger and indexer reads
License     : Apache-2.0

The live node and the indexer expose different consistency
boundaries:

* ledger queries may run through an acquired N2C LocalStateQuery
  snapshot;
* indexed transaction and UTxO reads run inside a
  @kv-transactions@ transaction over the indexer columns.

This module keeps those boundaries separate in the type of the
provider. CLI-style callers can open only the ledger side. HTTP or
server callers that own the indexer store can open both: the N2C
handle is acquired first, and the callback then runs inside the
indexer transaction.
-}
module Cardano.Node.Client.UTxOIndexer.Provider (
    -- * Provider modes
    ProviderMode (..),
    ProviderMonad,
    ProviderSingleton (..),
    Provider (..),

    -- * Ledger side
    LedgerQueryHandle (..),
    LedgerProvider (..),
    ledgerProviderFromProvider,
    ledgerProviderFromAcquired,

    -- * Indexer side
    IndexerProvider (..),
    indexerProvider,

    -- * Opening providers
    withProvider,

    -- * Errors
    IndexerProviderError (..),
) where

import Cardano.Crypto.Hash.Class (Hash (..), hashToBytes)
import Cardano.Ledger.Address (AccountAddress, Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (
    DecoderError,
    decodeFull',
 )
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, eraProtVerLow)
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.DRep (DRep)
import Cardano.Ledger.Hashes (
    extractHash,
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.State (GovState)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Provider qualified as Ledger
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Slotting.Slot (SlotNo)
import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Database.KV.Cursor (
    Cursor,
    Entry (..),
    nextEntry,
    seekKey,
 )
import Database.KV.Transaction (
    KV,
    RunTransaction (..),
    Transaction,
    iterating,
    query,
 )

{- | Provider capability modes.

The type parameters on 'LedgerAndIndexer' are the hidden
@kv-transactions@ backend types carried by a 'RunTransaction'.
-}
data ProviderMode
    = LedgerOnly
    | LedgerAndIndexer Type Type

{- | The callback monad selected by a provider mode.

Ledger-only callers run in 'IO'. Callers that open the indexer run
inside the indexer database transaction; N2C acquired reads are lifted
into that transaction.
-}
type family ProviderMonad (mode :: ProviderMode) (a :: Type) :: Type where
    ProviderMonad 'LedgerOnly a = IO a
    ProviderMonad ('LedgerAndIndexer cf op) a =
        Transaction IO cf Cols op a

{- | Runtime witness for a provider mode.

'SLedgerOnly' is the CLI shape. 'SLedgerAndIndexer' is the HTTP/server
shape: it has both the N2C ledger provider and the indexer transaction
runner.
-}
data ProviderSingleton mode where
    SLedgerOnly ::
        Ledger.Provider IO ->
        ProviderSingleton 'LedgerOnly
    SLedgerAndIndexer ::
        Ledger.Provider IO ->
        RunTransaction IO cf Cols op ->
        ProviderSingleton ('LedgerAndIndexer cf op)

-- | Provider value handed to the callback selected by a mode witness.
data Provider mode where
    LedgerOnlyProvider ::
        LedgerProvider IO ->
        Provider 'LedgerOnly
    LedgerAndIndexerProvider ::
        LedgerProvider (Transaction IO cf Cols op) ->
        IndexerProvider cf op ->
        Provider ('LedgerAndIndexer cf op)

{- | Non-UTxO operations bound to one acquired ledger snapshot.

The type intentionally has no UTxO selectors. Indexed UTxO and
transaction reads belong to 'IndexerProvider'.
-}
data LedgerQueryHandle m = LedgerQueryHandle
    { queryProtocolParamsLH ::
        m (PParams ConwayEra)
    , queryLedgerSnapshotLH ::
        m Ledger.LedgerSnapshot
    , queryStakeRewardsLH ::
        Set (Credential Staking) ->
        m (Map (Credential Staking) Coin)
    , queryRewardAccountsLH ::
        Set AccountAddress ->
        m (Map AccountAddress Coin)
    , queryVoteDelegateesLH ::
        Set (Credential Staking) ->
        m (Map (Credential Staking) DRep)
    , queryTreasuryLH ::
        m Coin
    , queryGovernanceStateLH ::
        m (GovState ConwayEra)
    , evaluateTxLH ::
        ConwayTx ->
        m (Ledger.EvaluateTxResult ConwayEra)
    , posixMsToSlotLH ::
        Integer ->
        m SlotNo
    , posixMsCeilSlotLH ::
        Integer ->
        m SlotNo
    }

-- | Non-UTxO ledger provider surface.
data LedgerProvider m = LedgerProvider
    { withAcquiredLedger ::
        forall a.
        (LedgerQueryHandle m -> m a) ->
        m a
    , queryProtocolParamsL ::
        m (PParams ConwayEra)
    , queryLedgerSnapshotL ::
        m Ledger.LedgerSnapshot
    , queryStakeRewardsL ::
        Set (Credential Staking) ->
        m (Map (Credential Staking) Coin)
    , queryRewardAccountsL ::
        Set AccountAddress ->
        m (Map AccountAddress Coin)
    , queryVoteDelegateesL ::
        Set (Credential Staking) ->
        m (Map (Credential Staking) DRep)
    , queryTreasuryL ::
        m Coin
    , queryGovernanceStateL ::
        m (GovState ConwayEra)
    , evaluateTxL ::
        ConwayTx ->
        m (Ledger.EvaluateTxResult ConwayEra)
    , posixMsToSlotL ::
        Integer ->
        m SlotNo
    , posixMsCeilSlotL ::
        Integer ->
        m SlotNo
    }

{- | Indexer-backed read surface.

These operations are database transactions. They do not use N2C and do
not pretend to be part of the acquired LSQ snapshot.
-}
data IndexerProvider cf op = IndexerProvider
    { queryIndexedUTxOs ::
        Addr ->
        Transaction IO cf Cols op [(TxIn, TxOut ConwayEra)]
    , queryIndexedUTxOsAt ::
        Set Addr ->
        Transaction IO cf Cols op (Map Addr [(TxIn, TxOut ConwayEra)])
    , queryIndexedUTxOByTxIn ::
        Set TxIn ->
        Transaction IO cf Cols op (Map TxIn (TxOut ConwayEra))
    }

{- | Error raised when indexed bytes cannot be decoded back into the
Conway-era ledger shape expected by transaction builders.
-}
data IndexerProviderError
    = IndexerProviderTxOutDecodeError Indexer.TxIn DecoderError
    deriving stock (Show)

instance Exception IndexerProviderError

-- | Open the provider selected by the mode witness.
withProvider ::
    ProviderSingleton mode ->
    (Provider mode -> ProviderMonad mode a) ->
    IO a
withProvider (SLedgerOnly ledger) action =
    action (LedgerOnlyProvider (ledgerProviderFromProvider ledger))
withProvider (SLedgerAndIndexer ledger runner) action =
    Ledger.withAcquired ledger $ \handle ->
        runTransaction runner $
            action $
                LedgerAndIndexerProvider
                    (ledgerProviderFromAcquired handle)
                    indexerProvider

-- | Drop UTxO selectors from a legacy ledger provider.
ledgerProviderFromProvider ::
    Ledger.Provider IO ->
    LedgerProvider IO
ledgerProviderFromProvider provider =
    LedgerProvider
        { withAcquiredLedger = \callback ->
            Ledger.withAcquired provider $
                callback . ledgerQueryHandleFromQueryHandle
        , queryProtocolParamsL = Ledger.queryProtocolParams provider
        , queryLedgerSnapshotL = Ledger.queryLedgerSnapshot provider
        , queryStakeRewardsL = Ledger.queryStakeRewards provider
        , queryRewardAccountsL = Ledger.queryRewardAccounts provider
        , queryVoteDelegateesL = Ledger.queryVoteDelegatees provider
        , queryTreasuryL = Ledger.queryTreasury provider
        , queryGovernanceStateL = Ledger.queryGovernanceState provider
        , evaluateTxL = Ledger.evaluateTx provider
        , posixMsToSlotL = Ledger.posixMsToSlot provider
        , posixMsCeilSlotL = Ledger.posixMsCeilSlot provider
        }

{- | Build a transaction-lifted ledger provider from an acquired N2C
query handle.

This is used by 'SLedgerAndIndexer': the acquired handle is opened once
outside the indexer transaction, then every ledger read is lifted into
the callback's transaction monad.
-}
ledgerProviderFromAcquired ::
    Ledger.QueryHandle IO ->
    LedgerProvider (Transaction IO cf Cols op)
ledgerProviderFromAcquired handle =
    LedgerProvider
        { withAcquiredLedger = \callback ->
            callback (ledgerQueryHandleFromAcquired handle)
        , queryProtocolParamsL =
            liftIO (Ledger.queryProtocolParamsH handle)
        , queryLedgerSnapshotL =
            liftIO (Ledger.queryLedgerSnapshotH handle)
        , queryStakeRewardsL =
            liftIO . Ledger.queryStakeRewardsH handle
        , queryRewardAccountsL =
            liftIO . Ledger.queryRewardAccountsH handle
        , queryVoteDelegateesL =
            liftIO . Ledger.queryVoteDelegateesH handle
        , queryTreasuryL =
            liftIO (Ledger.queryTreasuryH handle)
        , queryGovernanceStateL =
            liftIO (Ledger.queryGovernanceStateH handle)
        , evaluateTxL =
            liftIO . Ledger.evaluateTxH handle
        , posixMsToSlotL =
            liftIO . Ledger.posixMsToSlotH handle
        , posixMsCeilSlotL =
            liftIO . Ledger.posixMsCeilSlotH handle
        }

ledgerQueryHandleFromQueryHandle ::
    Ledger.QueryHandle IO ->
    LedgerQueryHandle IO
ledgerQueryHandleFromQueryHandle =
    hoistLedgerQueryHandle id

ledgerQueryHandleFromAcquired ::
    Ledger.QueryHandle IO ->
    LedgerQueryHandle (Transaction IO cf Cols op)
ledgerQueryHandleFromAcquired =
    hoistLedgerQueryHandle liftIO

hoistLedgerQueryHandle ::
    (forall x. m x -> n x) ->
    Ledger.QueryHandle m ->
    LedgerQueryHandle n
hoistLedgerQueryHandle nat handle =
    LedgerQueryHandle
        { queryProtocolParamsLH =
            nat (Ledger.queryProtocolParamsH handle)
        , queryLedgerSnapshotLH =
            nat (Ledger.queryLedgerSnapshotH handle)
        , queryStakeRewardsLH =
            nat . Ledger.queryStakeRewardsH handle
        , queryRewardAccountsLH =
            nat . Ledger.queryRewardAccountsH handle
        , queryVoteDelegateesLH =
            nat . Ledger.queryVoteDelegateesH handle
        , queryTreasuryLH =
            nat (Ledger.queryTreasuryH handle)
        , queryGovernanceStateLH =
            nat (Ledger.queryGovernanceStateH handle)
        , evaluateTxLH =
            nat . Ledger.evaluateTxH handle
        , posixMsToSlotLH =
            nat . Ledger.posixMsToSlotH handle
        , posixMsCeilSlotLH =
            nat . Ledger.posixMsCeilSlotH handle
        }

-- | Indexer transaction provider over the standard UTxO indexer columns.
indexerProvider :: IndexerProvider cf op
indexerProvider =
    IndexerProvider
        { queryIndexedUTxOs = queryIndexerUTxOs
        , queryIndexedUTxOsAt = queryIndexerUTxOsAt
        , queryIndexedUTxOByTxIn = queryIndexerUTxOByTxIn
        }

queryIndexerUTxOs ::
    Addr ->
    Transaction IO cf Cols op [(TxIn, TxOut ConwayEra)]
queryIndexerUTxOs addr =
    traverse decodeIndexedUTxO
        =<< iterating AddressIndex (scanAddress (toIndexerAddress addr))

queryIndexerUTxOsAt ::
    Set Addr ->
    Transaction IO cf Cols op (Map Addr [(TxIn, TxOut ConwayEra)])
queryIndexerUTxOsAt addrs =
    foldr add Map.empty <$> traverse queryAddress (Set.toList addrs)
  where
    queryAddress addr =
        (,) addr <$> queryIndexerUTxOs addr
    add (addr, utxos) = Map.insert addr utxos

queryIndexerUTxOByTxIn ::
    Set TxIn ->
    Transaction IO cf Cols op (Map TxIn (TxOut ConwayEra))
queryIndexerUTxOByTxIn txIns =
    Map.fromList . concat
        <$> traverse queryOne (Set.toList txIns)
  where
    queryOne txIn = do
        let indexedTxIn = toIndexerTxIn txIn
        mAddr <- query TxInCol indexedTxIn
        case mAddr of
            Nothing -> pure []
            Just addr -> do
                mTxOut <- query AddressIndex (Indexer.AddrKey addr indexedTxIn)
                case mTxOut of
                    Nothing -> pure []
                    Just indexedTxOut -> do
                        txOut <-
                            decodeIndexerTxOut indexedTxIn indexedTxOut
                        pure [(txIn, txOut)]

decodeIndexedUTxO ::
    (Indexer.TxIn, Indexer.TxOut) ->
    Transaction IO cf Cols op (TxIn, TxOut ConwayEra)
decodeIndexedUTxO (txIn, txOut) = do
    ledgerTxOut <- decodeIndexerTxOut txIn txOut
    pure (fromIndexerTxIn txIn, ledgerTxOut)

decodeIndexerTxOut ::
    Indexer.TxIn ->
    Indexer.TxOut ->
    Transaction IO cf Cols op (TxOut ConwayEra)
decodeIndexerTxOut txIn (Indexer.TxOut bytes) =
    case decodeFull' @(TxOut ConwayEra) (eraProtVerLow @ConwayEra) bytes of
        Right txOut -> pure txOut
        Left err ->
            liftIO $
                throwIO (IndexerProviderTxOutDecodeError txIn err)

scanAddress ::
    (Monad m) =>
    Indexer.Address ->
    Cursor m (KV Indexer.AddrKey Indexer.TxOut) [(Indexer.TxIn, Indexer.TxOut)]
scanAddress addr =
    let seekTo =
            Indexer.AddrKey
                addr
                (Indexer.TxIn (BS.replicate 32 0) 0)
     in seekKey seekTo >>= go []
  where
    go acc Nothing = pure (reverse acc)
    go acc (Just Entry{entryKey = key, entryValue = value})
        | Indexer.addrKeyAddress key == addr =
            nextEntry >>= go ((Indexer.addrKeyTxIn key, value) : acc)
        | otherwise = pure (reverse acc)

toIndexerAddress :: Addr -> Indexer.Address
toIndexerAddress =
    Indexer.Address . serialiseAddr

toIndexerTxIn :: TxIn -> Indexer.TxIn
toIndexerTxIn (TxIn (TxId safeHash) (TxIx ix)) =
    Indexer.TxIn
        { Indexer.txInId = hashToBytes (extractHash safeHash)
        , Indexer.txInIx = fromIntegral ix
        }

fromIndexerTxIn :: Indexer.TxIn -> TxIn
fromIndexerTxIn Indexer.TxIn{Indexer.txInId, Indexer.txInIx} =
    TxIn
        (TxId (unsafeMakeSafeHash (UnsafeHash (SBS.toShort txInId))))
        (TxIx (fromIntegral txInIx))
