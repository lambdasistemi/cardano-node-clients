module Cardano.Node.Client.TxDiff.CliSpec (spec) where

import Test.Hspec

import Cardano.Node.Client.TxDiff (
    HumanRenderOptions (..),
    RenderShape (..),
    TreeArt (..),
    defaultHumanRenderOptions,
 )
import Cardano.Node.Client.TxDiff.Cli (
    TxDiffCliError (..),
    TxDiffCliOptions (..),
    parseTxDiffCliArgs,
 )

spec :: Spec
spec =
    describe "tx-diff CLI parsing" $ do
        it "defaults to tree rendering with ASCII art" $
            parseTxDiffCliArgs ["tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right
                    TxDiffCliOptions
                        { txDiffCliBlueprintPaths = []
                        , txDiffCliHumanRenderOptions = defaultHumanRenderOptions
                        , txDiffCliLeftPath = "tx-a.cbor"
                        , txDiffCliRightPath = "tx-b.cbor"
                        }

        it "accepts explicit path rendering" $
            parseTxDiffCliArgs ["--render", "paths", "tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right
                    TxDiffCliOptions
                        { txDiffCliBlueprintPaths = []
                        , txDiffCliHumanRenderOptions =
                            defaultHumanRenderOptions
                                { humanRenderShape = RenderPaths
                                }
                        , txDiffCliLeftPath = "tx-a.cbor"
                        , txDiffCliRightPath = "tx-b.cbor"
                        }

        it "accepts explicit Unicode tree art" $
            parseTxDiffCliArgs ["--tree-art", "unicode", "tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right
                    TxDiffCliOptions
                        { txDiffCliBlueprintPaths = []
                        , txDiffCliHumanRenderOptions =
                            defaultHumanRenderOptions
                                { humanTreeArt = TreeArtUnicode
                                }
                        , txDiffCliLeftPath = "tx-a.cbor"
                        , txDiffCliRightPath = "tx-b.cbor"
                        }

        it "preserves repeated blueprint paths in input order" $
            parseTxDiffCliArgs
                [ "--blueprint"
                , "one.json"
                , "--blueprint"
                , "two.json"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Right
                    TxDiffCliOptions
                        { txDiffCliBlueprintPaths = ["one.json", "two.json"]
                        , txDiffCliHumanRenderOptions = defaultHumanRenderOptions
                        , txDiffCliLeftPath = "tx-a.cbor"
                        , txDiffCliRightPath = "tx-b.cbor"
                        }

        it "rejects invalid render mode before inputs are read" $
            parseTxDiffCliArgs ["--render", "json", "missing-a", "missing-b"]
                `shouldBe` Left
                    (TxDiffCliUsageError "unsupported --render value: json")

        it "rejects invalid tree art before inputs are read" $
            parseTxDiffCliArgs ["--tree-art", "emoji", "missing-a", "missing-b"]
                `shouldBe` Left
                    (TxDiffCliUsageError "unsupported --tree-art value: emoji")
