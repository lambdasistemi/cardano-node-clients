{-# LANGUAGE OverloadedLists #-}

module Cardano.Node.Client.TxDiffSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Test.Hspec

import Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    DiffPlan (..),
    OpenValue (..),
    diffOpenValue,
    diffWith,
 )

spec :: Spec
spec =
    describe "TxDiff structural traversal" $ do
        it "does not project children when the paired roots are equal" $ do
            let plan =
                    DiffPlan
                        { diffEqual = \_ _ -> True
                        , diffSummary = const Nothing
                        , diffProject =
                            \(_ :: ()) ->
                                error "equal roots must not be projected"
                        }
            diffWith plan () () `shouldBe` DiffNode rootPath (DiffSame Nothing)

        it "factors object keys into common, changed, onlyA, and onlyB" $ do
            let left =
                    OpenObject
                        [ ("same", OpenInteger 1)
                        , ("changed", OpenText "left")
                        , ("onlyA", OpenBytes "aa")
                        ]
                right =
                    OpenObject
                        [ ("same", OpenInteger 1)
                        , ("changed", OpenText "right")
                        , ("onlyB", OpenBytes "bb")
                        ]
            diffOpenValue left right
                `shouldBe` DiffNode
                    rootPath
                    ( DiffObject
                        (Map.fromList [("same", Just (Aeson.Number 1))])
                        ( Map.fromList
                            [
                                ( "changed"
                                , DiffNode
                                    (DiffPath ["changed"])
                                    ( DiffChanged
                                        (Aeson.String "left")
                                        (Aeson.String "right")
                                    )
                                )
                            ]
                        )
                        (Map.fromList [("onlyA", openBytesJson "aa")])
                        (Map.fromList [("onlyB", openBytesJson "bb")])
                    )

        it "recurses into changed nested objects and keeps equal children common" $ do
            let left =
                    OpenObject
                        [
                            ( "nested"
                            , OpenObject
                                [ ("keep", OpenText "same")
                                , ("change", OpenInteger 1)
                                ]
                            )
                        ]
                right =
                    OpenObject
                        [
                            ( "nested"
                            , OpenObject
                                [ ("keep", OpenText "same")
                                , ("change", OpenInteger 2)
                                ]
                            )
                        ]
            diffOpenValue left right
                `shouldBe` DiffNode
                    rootPath
                    ( DiffObject
                        Map.empty
                        ( Map.fromList
                            [
                                ( "nested"
                                , DiffNode
                                    (DiffPath ["nested"])
                                    ( DiffObject
                                        (Map.fromList [("keep", Just (Aeson.String "same"))])
                                        ( Map.fromList
                                            [
                                                ( "change"
                                                , DiffNode
                                                    (DiffPath ["nested", "change"])
                                                    ( DiffChanged
                                                        (Aeson.Number 1)
                                                        (Aeson.Number 2)
                                                    )
                                                )
                                            ]
                                        )
                                        Map.empty
                                        Map.empty
                                    )
                                )
                            ]
                        )
                        Map.empty
                        Map.empty
                    )

        it "aligns arrays by index and reports changed and tail entries" $ do
            let left =
                    OpenArray
                        [ OpenText "same"
                        , OpenInteger 1
                        , OpenText "left-tail"
                        ]
                right =
                    OpenArray
                        [ OpenText "same"
                        , OpenInteger 2
                        , OpenText "right-tail"
                        , OpenText "inserted"
                        ]
            diffOpenValue left right
                `shouldBe` DiffNode
                    rootPath
                    ( DiffArray
                        [(0, Just (Aeson.String "same"))]
                        [
                            ( 1
                            , DiffNode
                                (DiffPath ["1"])
                                ( DiffChanged
                                    (Aeson.Number 1)
                                    (Aeson.Number 2)
                                )
                            )
                        ,
                            ( 2
                            , DiffNode
                                (DiffPath ["2"])
                                ( DiffChanged
                                    (Aeson.String "left-tail")
                                    (Aeson.String "right-tail")
                                )
                            )
                        ]
                        []
                        [(3, Aeson.String "inserted")]
                    )

rootPath :: DiffPath
rootPath =
    DiffPath []

openBytesJson :: Aeson.Value -> Aeson.Value
openBytesJson bytes =
    Aeson.object ["bytes" .= bytes]
