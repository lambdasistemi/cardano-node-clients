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
    TxDiffCliN2cConfig (..),
    TxDiffCliOptions (..),
    TxDiffCliWeb2Config (..),
    parseTxDiffCliArgs,
 )

defaultOptions :: TxDiffCliOptions
defaultOptions =
    TxDiffCliOptions
        { txDiffCliBlueprintPaths = []
        , txDiffCliCollapseRulesPath = Nothing
        , txDiffCliHumanRenderOptions = defaultHumanRenderOptions
        , txDiffCliN2cResolver = Nothing
        , txDiffCliWeb2Resolver = Nothing
        , txDiffCliLeftPath = "tx-a.cbor"
        , txDiffCliRightPath = "tx-b.cbor"
        }

spec :: Spec
spec =
    describe "tx-diff CLI parsing" $ do
        it "defaults to tree rendering with ASCII art" $
            parseTxDiffCliArgs ["tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right defaultOptions

        it "accepts explicit path rendering" $
            parseTxDiffCliArgs ["--render", "paths", "tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliHumanRenderOptions =
                            defaultHumanRenderOptions
                                { humanRenderShape = RenderPaths
                                }
                        }

        it "accepts explicit Unicode tree art" $
            parseTxDiffCliArgs ["--tree-art", "unicode", "tx-a.cbor", "tx-b.cbor"]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliHumanRenderOptions =
                            defaultHumanRenderOptions
                                { humanTreeArt = TreeArtUnicode
                                }
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
                    defaultOptions
                        { txDiffCliBlueprintPaths = ["one.json", "two.json"]
                        }

        it "accepts a collapse rules path" $
            parseTxDiffCliArgs
                [ "--collapse-rules"
                , "collapse.yaml"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliCollapseRulesPath = Just "collapse.yaml"
                        }

        it "rejects invalid render mode before inputs are read" $
            parseTxDiffCliArgs ["--render", "json", "missing-a", "missing-b"]
                `shouldBe` Left
                    (TxDiffCliUsageError "unsupported --render value: json")

        it "rejects invalid tree art before inputs are read" $
            parseTxDiffCliArgs ["--tree-art", "emoji", "missing-a", "missing-b"]
                `shouldBe` Left
                    (TxDiffCliUsageError "unsupported --tree-art value: emoji")

        it "rejects a missing collapse rules path before inputs are read" $
            parseTxDiffCliArgs ["--collapse-rules"]
                `shouldBe` Left
                    (TxDiffCliUsageError "missing value for --collapse-rules")

        it "parses --resolve-n2c with --network-magic" $
            parseTxDiffCliArgs
                [ "--resolve-n2c"
                , "/run/cardano/node.socket"
                , "--network-magic"
                , "764824073"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliN2cResolver =
                            Just
                                TxDiffCliN2cConfig
                                    { txDiffCliN2cSocket = "/run/cardano/node.socket"
                                    , txDiffCliN2cNetworkMagic = 764824073
                                    }
                        }

        it "rejects --resolve-n2c without --network-magic" $
            parseTxDiffCliArgs
                [ "--resolve-n2c"
                , "/run/cardano/node.socket"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Left
                    ( TxDiffCliUsageError
                        "--resolve-n2c also requires --network-magic"
                    )

        it "rejects --network-magic without --resolve-n2c" $
            parseTxDiffCliArgs
                [ "--network-magic"
                , "1"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Left
                    ( TxDiffCliUsageError
                        "--network-magic also requires --resolve-n2c"
                    )

        it "rejects a non-numeric --network-magic" $
            parseTxDiffCliArgs
                [ "--network-magic"
                , "preprod"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Left
                    ( TxDiffCliUsageError
                        "expected a non-negative integer for --network-magic, got: preprod"
                    )

        it "parses --resolve-web2 without an API key file" $
            parseTxDiffCliArgs
                [ "--resolve-web2"
                , "https://example.invalid/api/v0"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliWeb2Resolver =
                            Just
                                TxDiffCliWeb2Config
                                    { txDiffCliWeb2Url =
                                        "https://example.invalid/api/v0"
                                    , txDiffCliWeb2ApiKeyFile = Nothing
                                    }
                        }

        it "parses --resolve-web2 with --web2-api-key-file" $
            parseTxDiffCliArgs
                [ "--resolve-web2"
                , "https://cardano-mainnet.blockfrost.io/api/v0"
                , "--web2-api-key-file"
                , "/run/secrets/blockfrost-mainnet"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Right
                    defaultOptions
                        { txDiffCliWeb2Resolver =
                            Just
                                TxDiffCliWeb2Config
                                    { txDiffCliWeb2Url =
                                        "https://cardano-mainnet.blockfrost.io/api/v0"
                                    , txDiffCliWeb2ApiKeyFile =
                                        Just "/run/secrets/blockfrost-mainnet"
                                    }
                        }

        it "rejects --web2-api-key-file without --resolve-web2" $
            parseTxDiffCliArgs
                [ "--web2-api-key-file"
                , "/run/secrets/blockfrost-mainnet"
                , "tx-a.cbor"
                , "tx-b.cbor"
                ]
                `shouldBe` Left
                    ( TxDiffCliUsageError
                        "--web2-api-key-file requires --resolve-web2"
                    )

        it "rejects --web2-api-key-file without its value" $
            parseTxDiffCliArgs
                [ "--resolve-web2"
                , "https://example.invalid/api/v0"
                , "--web2-api-key-file"
                ]
                `shouldBe` Left
                    ( TxDiffCliUsageError
                        "missing value for --web2-api-key-file"
                    )
