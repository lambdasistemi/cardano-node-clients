module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.AddressSpec qualified as AddressSpec
import Cardano.Node.Client.Adversary.ChainPointsSpec qualified as AdversaryChainPointsSpec
import Cardano.Node.Client.Adversary.ServerSpec qualified as AdversaryServerSpec
import Cardano.Node.Client.BlockIndexer.HandlerSpec qualified as BlockIndexerHandlerSpec
import Cardano.Node.Client.E2E.SetupSpec qualified as SetupSpec
import Cardano.Node.Client.N2C.LocalStateQuerySpec qualified as N2CLocalStateQuerySpec
import Cardano.Node.Client.N2C.ProbeSpec qualified as N2CProbeSpec
import Cardano.Node.Client.N2C.TraceSpec qualified as N2CTraceSpec
import Cardano.Node.Client.TxHistoryIndexer.HistoryRollbackSpec qualified as TxHistoryRollbackSpec
import Cardano.Node.Client.TxHistoryIndexer.IndexerSpec qualified as TxHistoryIndexerSpec
import Cardano.Node.Client.UTxOIndexer.AssetIndexSpec qualified as UTxOIndexerAssetIndexSpec
import Cardano.Node.Client.UTxOIndexer.AssetProvenanceSpec qualified as UTxOIndexerAssetProvenanceSpec
import Cardano.Node.Client.UTxOIndexer.AssetTypesSpec qualified as UTxOIndexerAssetTypesSpec
import Cardano.Node.Client.UTxOIndexer.AssetUpgradeSpec qualified as UTxOIndexerAssetUpgradeSpec
import Cardano.Node.Client.UTxOIndexer.AssetWireSpec qualified as UTxOIndexerAssetWireSpec
import Cardano.Node.Client.UTxOIndexer.BlockExtractSpec qualified as UTxOIndexerBlockExtractSpec
import Cardano.Node.Client.UTxOIndexer.DaemonDisclosureSpec qualified as UTxOIndexerDaemonDisclosureSpec
import Cardano.Node.Client.UTxOIndexer.DaemonSpec qualified as UTxOIndexerDaemonSpec
import Cardano.Node.Client.UTxOIndexer.DisclosureSpec qualified as UTxOIndexerDisclosureSpec
import Cardano.Node.Client.UTxOIndexer.DisclosureStabilitySpec qualified as UTxOIndexerDisclosureStabilitySpec
import Cardano.Node.Client.UTxOIndexer.DisclosureWireSpec qualified as UTxOIndexerDisclosureWireSpec
import Cardano.Node.Client.UTxOIndexer.FaultCheckSpec qualified as UTxOIndexerFaultCheckSpec
import Cardano.Node.Client.UTxOIndexer.FollowerSpec qualified as UTxOIndexerFollowerSpec
import Cardano.Node.Client.UTxOIndexer.IndexerSpec qualified as UTxOIndexerSpec
import Cardano.Node.Client.UTxOIndexer.MainnetSmokeSpec qualified as UTxOIndexerMainnetSmokeSpec
import Cardano.Node.Client.UTxOIndexer.PersistenceSpec qualified as UTxOIndexerPersistenceSpec
import Cardano.Node.Client.UTxOIndexer.ProviderSpec qualified as UTxOIndexerProviderSpec
import Cardano.Node.Client.UTxOIndexer.ServerSpec qualified as UTxOIndexerServerSpec
import Cardano.Node.Client.UTxOIndexer.ServerStabilitySpec qualified as UTxOIndexerServerStabilitySpec
import Cardano.Node.Client.UTxOIndexer.SharedFollowerSpec qualified as UTxOIndexerSharedFollowerSpec
import Cardano.Node.Client.UTxOIndexer.TxOutViewSpec qualified as UTxOIndexerTxOutViewSpec
import Cardano.Node.Client.UTxOIndexer.TypesSpec qualified as UTxOIndexerTypesSpec
import Cardano.Node.Client.UTxOIndexer.WarmBootSpec qualified as UTxOIndexerWarmBootSpec
import Cardano.Node.Client.ValiditySpec qualified as ValiditySpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    SetupSpec.spec
    AdversaryChainPointsSpec.spec
    AdversaryServerSpec.spec
    BlockIndexerHandlerSpec.spec
    AddressSpec.spec
    SampleFibonacciSpec.spec
    UTxOIndexerTypesSpec.spec
    UTxOIndexerWarmBootSpec.spec
    UTxOIndexerTxOutViewSpec.spec
    UTxOIndexerAssetIndexSpec.spec
    UTxOIndexerAssetProvenanceSpec.spec
    UTxOIndexerAssetTypesSpec.spec
    UTxOIndexerAssetUpgradeSpec.spec
    UTxOIndexerAssetWireSpec.spec
    UTxOIndexerBlockExtractSpec.spec
    UTxOIndexerSpec.spec
    UTxOIndexerServerSpec.spec
    UTxOIndexerServerStabilitySpec.spec
    UTxOIndexerDisclosureSpec.spec
    UTxOIndexerDisclosureWireSpec.spec
    UTxOIndexerDisclosureStabilitySpec.spec
    UTxOIndexerPersistenceSpec.spec
    UTxOIndexerProviderSpec.spec
    UTxOIndexerDaemonSpec.spec
    UTxOIndexerDaemonDisclosureSpec.spec
    UTxOIndexerFaultCheckSpec.spec
    UTxOIndexerFollowerSpec.spec
    UTxOIndexerMainnetSmokeSpec.spec
    N2CLocalStateQuerySpec.spec
    N2CProbeSpec.spec
    N2CTraceSpec.spec
    TxHistoryIndexerSpec.spec
    TxHistoryRollbackSpec.spec
    UTxOIndexerSharedFollowerSpec.spec
    ValiditySpec.spec
