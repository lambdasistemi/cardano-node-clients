module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.E2E.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.E2E.ChainPopulatorSpec qualified as ChainPopulatorSpec
import Cardano.Node.Client.E2E.ChainSyncSpec qualified as ChainSyncSpec
import Cardano.Node.Client.E2E.Issue97ReproSpec qualified as Issue97ReproSpec
import Cardano.Node.Client.E2E.MultiAssetChangeSpec qualified as MultiAssetChangeSpec
import Cardano.Node.Client.E2E.N2CFullSpec qualified as N2CFullSpec
import Cardano.Node.Client.E2E.ProviderSpec qualified as ProviderSpec
import Cardano.Node.Client.E2E.TxBuildSpec qualified as TxBuildSpec
import Cardano.Node.Client.E2E.TxGeneratorEnduranceSpec qualified as TxGeneratorEnduranceSpec
import Cardano.Node.Client.E2E.TxGeneratorReadySpec qualified as TxGeneratorReadySpec
import Cardano.Node.Client.E2E.TxGeneratorRefillSpec qualified as TxGeneratorRefillSpec
import Cardano.Node.Client.E2E.TxGeneratorRestartSpec qualified as TxGeneratorRestartSpec
import Cardano.Node.Client.E2E.TxGeneratorSnapshotSpec qualified as TxGeneratorSnapshotE2ESpec
import Cardano.Node.Client.E2E.TxGeneratorStarvationSpec qualified as TxGeneratorStarvationSpec
import Cardano.Node.Client.E2E.TxGeneratorTransactSpec qualified as TxGeneratorTransactSpec
import Cardano.Node.Client.E2E.UTxOIndexerSpec qualified as UTxOIndexerSpec

main :: IO ()
main = hspec $ do
    ProviderSpec.spec
    BalanceSpec.spec
    TxBuildSpec.spec
    MultiAssetChangeSpec.spec
    ChainSyncSpec.spec
    N2CFullSpec.spec
    ChainPopulatorSpec.spec
    UTxOIndexerSpec.spec
    Issue97ReproSpec.spec
    TxGeneratorReadySpec.spec
    TxGeneratorRefillSpec.spec
    TxGeneratorTransactSpec.spec
    TxGeneratorSnapshotE2ESpec.spec
    TxGeneratorRestartSpec.spec
    TxGeneratorEnduranceSpec.spec
    TxGeneratorStarvationSpec.spec
