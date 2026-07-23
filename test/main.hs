module Main (main) where

import Test.Hspec (hspec)

import Cardano.Node.Client.E2E.ChainSyncSpec qualified as ChainSyncSpec
import Cardano.Node.Client.E2E.GovernanceEnactmentSpec qualified as GovernanceEnactmentSpec
import Cardano.Node.Client.E2E.HorizonSpec qualified as HorizonSpec
import Cardano.Node.Client.E2E.Issue97ReproSpec qualified as Issue97ReproSpec
import Cardano.Node.Client.E2E.N2CFullSpec qualified as N2CFullSpec
import Cardano.Node.Client.E2E.ProviderSpec qualified as ProviderSpec
import Cardano.Node.Client.E2E.UTxOIndexerReconnectSpec qualified as UTxOIndexerReconnectSpec

main :: IO ()
main = hspec $ do
    ProviderSpec.spec
    ChainSyncSpec.spec
    N2CFullSpec.spec
    UTxOIndexerReconnectSpec.spec
    HorizonSpec.spec
    Issue97ReproSpec.spec
    GovernanceEnactmentSpec.spec
