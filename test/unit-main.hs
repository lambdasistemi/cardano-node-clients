module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.TxBuildGoldenSpec qualified as TxBuildGoldenSpec
import Cardano.Node.Client.TxBuildSpec qualified as TxBuildSpec
import Cardano.Node.Client.TxGenerator.PersistSpec qualified as TxGeneratorPersistSpec
import Cardano.Node.Client.TxGenerator.PopulationSpec qualified as TxGeneratorPopulationSpec
import Cardano.Node.Client.UTxOIndexer.IndexerSpec qualified as UTxOIndexerSpec
import Cardano.Node.Client.UTxOIndexer.PersistenceSpec qualified as UTxOIndexerPersistenceSpec
import Cardano.Node.Client.UTxOIndexer.ServerSpec qualified as UTxOIndexerServerSpec
import Cardano.Node.Client.UTxOIndexer.TypesSpec qualified as UTxOIndexerTypesSpec
import Data.List.SampleFibonacciSpec qualified as SampleFibonacciSpec

main :: IO ()
main = hspec $ do
    SampleFibonacciSpec.spec
    BalanceSpec.spec
    TxBuildSpec.spec
    TxBuildGoldenSpec.spec
    UTxOIndexerTypesSpec.spec
    UTxOIndexerSpec.spec
    UTxOIndexerServerSpec.spec
    UTxOIndexerPersistenceSpec.spec
    TxGeneratorPersistSpec.spec
    TxGeneratorPopulationSpec.spec
