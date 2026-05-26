module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.AddressSpec qualified as AddressSpec
import Cardano.Node.Client.N2C.ProbeSpec qualified as N2CProbeSpec
import Cardano.Node.Client.N2C.TraceSpec qualified as N2CTraceSpec
import Cardano.Node.Client.UTxOIndexer.DaemonSpec qualified as UTxOIndexerDaemonSpec
import Cardano.Node.Client.UTxOIndexer.FollowerSpec qualified as UTxOIndexerFollowerSpec
import Cardano.Node.Client.UTxOIndexer.IndexerSpec qualified as UTxOIndexerSpec
import Cardano.Node.Client.UTxOIndexer.MainnetSmokeSpec qualified as UTxOIndexerMainnetSmokeSpec
import Cardano.Node.Client.UTxOIndexer.PersistenceSpec qualified as UTxOIndexerPersistenceSpec
import Cardano.Node.Client.UTxOIndexer.ServerSpec qualified as UTxOIndexerServerSpec
import Cardano.Node.Client.UTxOIndexer.TypesSpec qualified as UTxOIndexerTypesSpec
import Cardano.Node.Client.ValiditySpec qualified as ValiditySpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    AddressSpec.spec
    SampleFibonacciSpec.spec
    UTxOIndexerTypesSpec.spec
    UTxOIndexerSpec.spec
    UTxOIndexerServerSpec.spec
    UTxOIndexerPersistenceSpec.spec
    UTxOIndexerDaemonSpec.spec
    UTxOIndexerFollowerSpec.spec
    UTxOIndexerMainnetSmokeSpec.spec
    N2CProbeSpec.spec
    N2CTraceSpec.spec
    ValiditySpec.spec
