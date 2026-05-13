module Cardano.Node.Client.TxDiffSpec (spec) where

import Test.Hspec

import Cardano.Node.Client.TxDiff.ConwaySpec qualified as ConwaySpec
import Cardano.Node.Client.TxDiff.CoreSpec qualified as CoreSpec

spec :: Spec
spec =
    describe "TxDiff structural traversal" $ do
        CoreSpec.spec
        ConwaySpec.spec
