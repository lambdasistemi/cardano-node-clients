module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.AddressSpec qualified as AddressSpec
import Cardano.Node.Client.Adversary.ChainPointsSpec qualified as AdversaryChainPointsSpec
import Cardano.Node.Client.Adversary.ServerSpec qualified as AdversaryServerSpec
import Cardano.Node.Client.BlockIndexer.HandlerSpec qualified as BlockIndexerHandlerSpec
import Cardano.Node.Client.N2C.LocalStateQuerySpec qualified as N2CLocalStateQuerySpec
import Cardano.Node.Client.N2C.ProbeSpec qualified as N2CProbeSpec
import Cardano.Node.Client.N2C.TraceSpec qualified as N2CTraceSpec
import Cardano.Node.Client.TxHistoryIndexer.HistoryRollbackSpec qualified as TxHistoryRollbackSpec
import Cardano.Node.Client.TxHistoryIndexer.IndexerSpec qualified as TxHistoryIndexerSpec
import Cardano.Node.Client.UTxOIndexer.BlockExtractSpec qualified as UTxOIndexerBlockExtractSpec
import Cardano.Node.Client.UTxOIndexer.DaemonSpec qualified as UTxOIndexerDaemonSpec
import Cardano.Node.Client.UTxOIndexer.FollowerSpec qualified as UTxOIndexerFollowerSpec
import Cardano.Node.Client.UTxOIndexer.IndexerSpec qualified as UTxOIndexerSpec
import Cardano.Node.Client.UTxOIndexer.MainnetSmokeSpec qualified as UTxOIndexerMainnetSmokeSpec
import Cardano.Node.Client.UTxOIndexer.PersistenceSpec qualified as UTxOIndexerPersistenceSpec
import Cardano.Node.Client.UTxOIndexer.ProviderSpec qualified as UTxOIndexerProviderSpec
import Cardano.Node.Client.UTxOIndexer.ServerSpec qualified as UTxOIndexerServerSpec
import Cardano.Node.Client.UTxOIndexer.SharedFollowerSpec qualified as UTxOIndexerSharedFollowerSpec
import Cardano.Node.Client.UTxOIndexer.TypesSpec qualified as UTxOIndexerTypesSpec
import Cardano.Node.Client.ValiditySpec qualified as ValiditySpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    AdversaryChainPointsSpec.spec
    AdversaryServerSpec.spec
    BlockIndexerHandlerSpec.spec
    AddressSpec.spec
    SampleFibonacciSpec.spec
    UTxOIndexerTypesSpec.spec
    UTxOIndexerBlockExtractSpec.spec
    UTxOIndexerSpec.spec
    UTxOIndexerServerSpec.spec
    UTxOIndexerPersistenceSpec.spec
    UTxOIndexerProviderSpec.spec
    UTxOIndexerDaemonSpec.spec
    UTxOIndexerFollowerSpec.spec
    UTxOIndexerMainnetSmokeSpec.spec
    N2CLocalStateQuerySpec.spec
    N2CProbeSpec.spec
    N2CTraceSpec.spec
    TxHistoryIndexerSpec.spec
    TxHistoryRollbackSpec.spec
    UTxOIndexerSharedFollowerSpec.spec
    ValiditySpec.spec
