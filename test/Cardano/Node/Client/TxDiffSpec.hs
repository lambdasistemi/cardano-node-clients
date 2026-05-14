module Cardano.Node.Client.TxDiffSpec (spec) where

import Test.Hspec

import Cardano.Node.Client.TxDiff.BlueprintSpec qualified as BlueprintSpec
import Cardano.Node.Client.TxDiff.CliSpec qualified as CliSpec
import Cardano.Node.Client.TxDiff.ConwaySpec qualified as ConwaySpec
import Cardano.Node.Client.TxDiff.CoreSpec qualified as CoreSpec
import Cardano.Node.Client.TxDiff.ResolverSpec qualified as ResolverSpec
import Cardano.Node.Client.TxDiff.Web2Spec qualified as Web2Spec

spec :: Spec
spec =
    describe "TxDiff structural traversal" $ do
        BlueprintSpec.spec
        CliSpec.spec
        CoreSpec.spec
        ConwaySpec.spec
        ResolverSpec.spec
        Web2Spec.spec
