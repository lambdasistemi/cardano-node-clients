module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.Adversary.ServerSpec qualified as AdversaryServerSpec
import Cardano.Node.Client.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.TxBuildGoldenSpec qualified as TxBuildGoldenSpec
import Cardano.Node.Client.TxBuildSpec qualified as TxBuildSpec
import Cardano.Node.Client.TxGenerator.FanoutSpec qualified as TxGeneratorFanoutSpec
import Cardano.Node.Client.TxGenerator.PersistSpec qualified as TxGeneratorPersistSpec
import Cardano.Node.Client.TxGenerator.PopulationSpec qualified as TxGeneratorPopulationSpec
import Cardano.Node.Client.TxGenerator.SelectionSpec qualified as TxGeneratorSelectionSpec
import Cardano.Node.Client.TxGenerator.ServerSpec qualified as TxGeneratorServerSpec
import Cardano.Node.Client.TxGenerator.SnapshotSpec qualified as TxGeneratorSnapshotSpec
import Cardano.Node.Client.UTxOIndexer.IndexerSpec qualified as UTxOIndexerSpec
import Cardano.Node.Client.UTxOIndexer.PersistenceSpec qualified as UTxOIndexerPersistenceSpec
import Cardano.Node.Client.UTxOIndexer.ServerSpec qualified as UTxOIndexerServerSpec
import Cardano.Node.Client.UTxOIndexer.TypesSpec qualified as UTxOIndexerTypesSpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    SampleFibonacciSpec.spec
    AdversaryServerSpec.spec
    BalanceSpec.spec
    TxBuildSpec.spec
    TxBuildGoldenSpec.spec
    UTxOIndexerTypesSpec.spec
    UTxOIndexerSpec.spec
    UTxOIndexerServerSpec.spec
    UTxOIndexerPersistenceSpec.spec
    TxGeneratorFanoutSpec.spec
    TxGeneratorPersistSpec.spec
    TxGeneratorPopulationSpec.spec
    TxGeneratorSelectionSpec.spec
    TxGeneratorServerSpec.spec
    TxGeneratorSnapshotSpec.spec
