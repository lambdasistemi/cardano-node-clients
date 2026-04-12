module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.E2E.BalanceSpec qualified as BalanceSpec
import Cardano.Node.Client.E2E.ChainPopulatorSpec qualified as ChainPopulatorSpec
import Cardano.Node.Client.E2E.ChainSyncSpec qualified as ChainSyncSpec
import Cardano.Node.Client.E2E.ProviderSpec qualified as ProviderSpec
import Cardano.Node.Client.E2E.TxBuildSpec qualified as TxBuildSpec

main :: IO ()
main = hspec $ do
    ProviderSpec.spec
    BalanceSpec.spec
    TxBuildSpec.spec
    ChainSyncSpec.spec
    ChainPopulatorSpec.spec
