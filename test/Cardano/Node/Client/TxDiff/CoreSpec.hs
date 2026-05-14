{-# LANGUAGE OverloadedLists #-}

module Cardano.Node.Client.TxDiff.CoreSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Hspec
import Test.QuickCheck (
    Arbitrary (..),
    Gen,
    Property,
    choose,
    conjoin,
    counterexample,
    elements,
    frequency,
    property,
    sized,
    vectorOf,
    (===),
    (==>),
 )

import Cardano.Node.Client.TxDiff (
    CollapseRawView (..),
    CollapseRule (..),
    CollapseRules (..),
    DiffChange (..),
    DiffNode (..),
    DiffPath (..),
    DiffPlan (..),
    HumanRenderOptions (..),
    OpenValue (..),
    RenderShape (..),
    TreeArt (..),
    defaultHumanRenderOptions,
    diffOpenValue,
    diffWith,
    parseCollapseRulesYaml,
    renderDiffNodeHuman,
    renderDiffNodeHumanWith,
 )

spec :: Spec
spec =
    describe "open values" $ do
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

        it "renders collected diff tree as grouped ASCII tree by default" $ do
            let left =
                    OpenObject
                        [
                            ( "body"
                            , OpenObject
                                [ ("fee", OpenInteger 1)
                                , ("ttl", OpenInteger 10)
                                , ("same", OpenText "keep")
                                ]
                            )
                        ]
                right =
                    OpenObject
                        [
                            ( "body"
                            , OpenObject
                                [ ("fee", OpenInteger 20)
                                , ("ttl", OpenInteger 11)
                                , ("same", OpenText "keep")
                                ]
                            )
                        ]
            renderDiffNodeHuman (diffOpenValue left right)
                `shouldBe` Text.unlines
                    [ "body"
                    , "+- fee"
                    , "|  +- A:  1"
                    , "|  `- B: 20"
                    , "`- ttl"
                    , "   +- A: 10"
                    , "   `- B: 11"
                    ]

        it "renders collected diff tree as explicit path lines" $ do
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
                options =
                    defaultHumanRenderOptions
                        { humanRenderShape = RenderPaths
                        }
            renderDiffNodeHumanWith options (diffOpenValue left right)
                `shouldBe` Text.unlines
                    [ "~ changed"
                    , "  A: \"left\""
                    , "  B: \"right\""
                    , "- onlyA: {\"bytes\":\"aa\"}"
                    , "+ onlyB: {\"bytes\":\"bb\"}"
                    ]

        it "preserves array-only tail entries in explicit path mode" $ do
            let left =
                    OpenArray
                        [ OpenText "same"
                        , OpenText "left-tail"
                        ]
                right =
                    OpenArray
                        [ OpenText "same"
                        , OpenText "right-tail"
                        , OpenText "inserted"
                        ]
                options =
                    defaultHumanRenderOptions
                        { humanRenderShape = RenderPaths
                        }
            renderDiffNodeHumanWith options (diffOpenValue left right)
                `shouldBe` Text.unlines
                    [ "~ 1"
                    , "  A: \"left-tail\""
                    , "  B: \"right-tail\""
                    , "+ 2: \"inserted\""
                    ]

        it "renders tree output with Unicode connector art on request" $ do
            let left =
                    OpenObject
                        [
                            ( "body"
                            , OpenObject
                                [ ("fee", OpenInteger 1)
                                , ("ttl", OpenInteger 10)
                                ]
                            )
                        ]
                right =
                    OpenObject
                        [
                            ( "body"
                            , OpenObject
                                [ ("fee", OpenInteger 20)
                                , ("ttl", OpenInteger 11)
                                ]
                            )
                        ]
                options =
                    defaultHumanRenderOptions
                        { humanTreeArt = TreeArtUnicode
                        }
            renderDiffNodeHumanWith options (diffOpenValue left right)
                `shouldBe` Text.unlines
                    [ "body"
                    , " ├╴fee"
                    , " │  ├╴A:  1"
                    , " │  └╴B: 20"
                    , " └╴ttl"
                    , "    ├╴A: 10"
                    , "    └╴B: 11"
                    ]

        it "orders numeric tree path segments numerically" $ do
            let left =
                    OpenObject
                        [
                            ( "outputs"
                            , OpenArray
                                [ OpenText "same"
                                , OpenText "same"
                                , OpenInteger 2
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenInteger 10
                                ]
                            )
                        ]
                right =
                    OpenObject
                        [
                            ( "outputs"
                            , OpenArray
                                [ OpenText "same"
                                , OpenText "same"
                                , OpenInteger 20
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenText "same"
                                , OpenInteger 100
                                ]
                            )
                        ]
            renderDiffNodeHuman (diffOpenValue left right)
                `shouldBe` Text.unlines
                    [ "outputs"
                    , "+- 2"
                    , "|  +- A:  2"
                    , "|  `- B: 20"
                    , "`- 10"
                    , "   +- A:  10"
                    , "   `- B: 100"
                    ]

        it "parses YAML collapse rules as named overlays" $ do
            parseCollapseRulesYaml
                ( BS8.pack
                    "version: 1\n\
                    \views:\n\
                    \  raw: hide\n\
                    \collapse:\n\
                    \  - name: swapOrders\n\
                    \    at: outputs\n\
                    \    match:\n\
                    \      required:\n\
                    \        - coin\n\
                    \        - datum.fields.4.fields.0.2\n"
                )
                `shouldBe` Right
                    CollapseRules
                        { collapseRawView = CollapseRawHide
                        , collapseRules =
                            [ CollapseRule
                                { collapseRuleName = "swapOrders"
                                , collapseRuleAt = DiffPath ["outputs"]
                                , collapseRuleRequired =
                                    [ DiffPath ["coin"]
                                    , DiffPath
                                        [ "datum"
                                        , "fields"
                                        , "4"
                                        , "fields"
                                        , "0"
                                        , "2"
                                        ]
                                    ]
                                }
                            ]
                        }

        it "moves list indexes down to named collapse view leaves" $ do
            let options =
                    defaultHumanRenderOptions
                        { humanCollapseRules =
                            Just
                                CollapseRules
                                    { collapseRawView = CollapseRawHide
                                    , collapseRules =
                                        [ CollapseRule
                                            { collapseRuleName = "swapOrders"
                                            , collapseRuleAt = DiffPath ["outputs"]
                                            , collapseRuleRequired =
                                                [ DiffPath ["coin"]
                                                , DiffPath
                                                    [ "datum"
                                                    , "fields"
                                                    , "4"
                                                    , "fields"
                                                    , "0"
                                                    , "2"
                                                    ]
                                                , DiffPath
                                                    [ "datum"
                                                    , "fields"
                                                    , "4"
                                                    , "fields"
                                                    , "1"
                                                    , "2"
                                                    ]
                                                ]
                                            }
                                        ]
                                    }
                        }
                output =
                    renderDiffNodeHumanWith
                        options
                        (diffOpenValue collapsedLeft collapsedRight)
            output
                `shouldBe` Text.unlines
                    [ "outputs"
                    , "`- swapOrders"
                    , "   +- coin"
                    , "   |  +- 0..1"
                    , "   |  |  +- A: 10"
                    , "   |  |  `- B: 20"
                    , "   |  `- 2"
                    , "   |     +- A: 11"
                    , "   |     `- B: 21"
                    , "   `- datum"
                    , "      `- fields"
                    , "         `- 4"
                    , "            `- fields"
                    , "               +- 0"
                    , "               |  `- 2"
                    , "               |     +- 0..1"
                    , "               |     |  +- A: 100"
                    , "               |     |  `- B: 200"
                    , "               |     `- 2"
                    , "               |        +- A: 101"
                    , "               |        `- B: 201"
                    , "               `- 1"
                    , "                  `- 2"
                    , "                     `- 0..2"
                    , "                        +- A: 300"
                    , "                        `- B: 400"
                    ]

        it "renders intersecting collapse rules as independent named overlays" $ do
            let options =
                    defaultHumanRenderOptions
                        { humanCollapseRules =
                            Just
                                CollapseRules
                                    { collapseRawView = CollapseRawHide
                                    , collapseRules =
                                        [ CollapseRule
                                            { collapseRuleName = "swapOrders"
                                            , collapseRuleAt = DiffPath ["outputs"]
                                            , collapseRuleRequired =
                                                [ DiffPath ["coin"]
                                                , DiffPath
                                                    [ "datum"
                                                    , "fields"
                                                    , "4"
                                                    , "fields"
                                                    , "0"
                                                    , "2"
                                                    ]
                                                ]
                                            }
                                        , CollapseRule
                                            { collapseRuleName = "coinChanges"
                                            , collapseRuleAt = DiffPath ["outputs"]
                                            , collapseRuleRequired =
                                                [DiffPath ["coin"]]
                                            }
                                        ]
                                    }
                        }
                output =
                    renderDiffNodeHumanWith
                        options
                        (diffOpenValue collapsedLeft collapsedRight)
            output `shouldSatisfy` Text.isInfixOf "coinChanges"
            output `shouldSatisfy` Text.isInfixOf "swapOrders"
            output `shouldSatisfy` Text.isInfixOf "0..1"
            output `shouldSatisfy` Text.isInfixOf "A: 10"
            output `shouldSatisfy` Text.isInfixOf "B: 20"

        it "keeps raw list rendering visible unless collapse rules hide it" $ do
            let rules rawView =
                    CollapseRules
                        { collapseRawView = rawView
                        , collapseRules =
                            [ CollapseRule
                                { collapseRuleName = "coinChanges"
                                , collapseRuleAt = DiffPath ["outputs"]
                                , collapseRuleRequired = [DiffPath ["coin"]]
                                }
                            ]
                        }
                renderWith rawView =
                    renderDiffNodeHumanWith
                        defaultHumanRenderOptions
                            { humanCollapseRules = Just (rules rawView)
                            }
                        (diffOpenValue collapsedLeft collapsedRight)
                rawOutput =
                    renderWith CollapseRawShow
                hiddenOutput =
                    renderWith CollapseRawHide
            rawOutput `shouldSatisfy` Text.isInfixOf "`- raw"
            hiddenOutput `shouldNotSatisfy` Text.isInfixOf "raw"

        it "keeps numeric list item diffs visible when raw view is hidden" $ do
            let options =
                    defaultHumanRenderOptions
                        { humanCollapseRules =
                            Just
                                CollapseRules
                                    { collapseRawView = CollapseRawHide
                                    , collapseRules =
                                        [ CollapseRule
                                            { collapseRuleName = "swapOrders"
                                            , collapseRuleAt = DiffPath ["outputs"]
                                            , collapseRuleRequired =
                                                [ DiffPath ["coin"]
                                                , DiffPath
                                                    [ "datum"
                                                    , "fields"
                                                    , "4"
                                                    , "fields"
                                                    , "0"
                                                    , "2"
                                                    ]
                                                ]
                                            }
                                        ]
                                    }
                        }
                output =
                    renderDiffNodeHumanWith
                        options
                        (diffOpenValue remainderLeft remainderRight)
            output
                `shouldBe` Text.unlines
                    [ "outputs"
                    , "+- swapOrders"
                    , "|  +- coin"
                    , "|  |  +- 0..1"
                    , "|  |  |  +- A: 10"
                    , "|  |  |  `- B: 20"
                    , "|  |  `- 2"
                    , "|  |     +- A: 11"
                    , "|  |     `- B: 21"
                    , "|  `- datum"
                    , "|     `- fields"
                    , "|        `- 4"
                    , "|           `- fields"
                    , "|              `- 0"
                    , "|                 `- 2"
                    , "|                    +- 0..1"
                    , "|                    |  +- A: 100"
                    , "|                    |  `- B: 200"
                    , "|                    `- 2"
                    , "|                       +- A: 101"
                    , "|                       `- B: 201"
                    , "+- 0"
                    , "|  `- datum"
                    , "|     `- fields"
                    , "|        `- 4"
                    , "|           `- fields"
                    , "|              `- 1"
                    , "|                 `- 2"
                    , "|                    +- A: 300"
                    , "|                    `- B: 400"
                    , "+- 1"
                    , "|  `- datum"
                    , "|     `- fields"
                    , "|        `- 4"
                    , "|           `- fields"
                    , "|              `- 1"
                    , "|                 `- 2"
                    , "|                    +- A: 300"
                    , "|                    `- B: 400"
                    , "+- 2"
                    , "|  `- datum"
                    , "|     `- fields"
                    , "|        `- 4"
                    , "|           `- fields"
                    , "|              `- 1"
                    , "|                 `- 2"
                    , "|                    +- A: 300"
                    , "|                    `- B: 400"
                    , "`- 3"
                    , "   `- coin"
                    , "      +- A: 12"
                    , "      `- B: 22"
                    ]

        it "renders known coin values with exact ADA and lovelace units" $ do
            let diff =
                    DiffNode
                        (DiffPath ["body", "fee"])
                        ( DiffChanged
                            (Aeson.object ["lovelace" .= (1_000_000 :: Integer)])
                            (Aeson.object ["lovelace" .= (1_500_000 :: Integer)])
                        )
            renderDiffNodeHuman diff
                `shouldBe` Text.unlines
                    [ "body"
                    , "`- fee"
                    , "   +- A: 1.000000 ADA (1000000 lovelace)"
                    , "   `- B: 1.500000 ADA (1500000 lovelace)"
                    ]

        it "summarizes raw CBOR payloads in human-readable output" $ do
            let diff =
                    DiffNode
                        (DiffPath ["body", "outputs", "0", "datum"])
                        ( DiffChanged
                            (Aeson.object ["cbor" .= Text.replicate 80 "a"])
                            (Aeson.object ["cbor" .= Text.replicate 80 "b"])
                        )
            renderDiffNodeHuman diff
                `shouldBe` Text.unlines
                    [ "body"
                    , "`- outputs"
                    , "   `- 0"
                    , "      `- datum"
                    , "         +- A: cbor:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa... (40 bytes)"
                    , "         `- B: cbor:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb... (40 bytes)"
                    ]

        it "reports any equal generated value as same at the root" $
            property $
                \(SmallOpenValue value) ->
                    diffOpenValue value value
                        === DiffNode rootPath (DiffSame (openValueSummary value))

        it "partitions generated object keys soundly" $
            property $
                \(SmallOpenObject left) (SmallOpenObject right) ->
                    if left == right
                        then
                            diffOpenValue (OpenObject left) (OpenObject right)
                                === DiffNode rootPath (DiffSame Nothing)
                        else case diffOpenValue (OpenObject left) (OpenObject right) of
                            DiffNode path (DiffObject common changed onlyA onlyB) ->
                                let leftKeys = Map.keysSet left
                                    rightKeys = Map.keysSet right
                                    sharedKeys = Set.intersection leftKeys rightKeys
                                    expectedCommon =
                                        Set.filter
                                            ( \key ->
                                                Map.lookup key left == Map.lookup key right
                                            )
                                            sharedKeys
                                    expectedChanged =
                                        Set.filter
                                            ( \key ->
                                                Map.lookup key left /= Map.lookup key right
                                            )
                                            sharedKeys
                                 in conjoin
                                        [ path === rootPath
                                        , Map.keysSet common === expectedCommon
                                        , Map.keysSet changed === expectedChanged
                                        , Map.keysSet onlyA
                                            === Set.difference leftKeys rightKeys
                                        , Map.keysSet onlyB
                                            === Set.difference rightKeys leftKeys
                                        , changedPathsAreObjectKeys changed
                                        ]
                            other ->
                                counterexample ("unexpected object diff: " <> show other) False

        it "partitions generated arrays by aligned index and tail entries" $
            property $
                \(SmallOpenArray left) (SmallOpenArray right) ->
                    if left == right
                        then
                            diffOpenValue (OpenArray left) (OpenArray right)
                                === DiffNode rootPath (DiffSame Nothing)
                        else case diffOpenValue (OpenArray left) (OpenArray right) of
                            DiffNode path (DiffArray common changed onlyA onlyB) ->
                                let paired = zip [0 :: Int ..] (zip left right)
                                    expectedCommon =
                                        [ index
                                        | (index, (leftValue, rightValue)) <- paired
                                        , leftValue == rightValue
                                        ]
                                    expectedChanged =
                                        [ index
                                        | (index, (leftValue, rightValue)) <- paired
                                        , leftValue /= rightValue
                                        ]
                                    expectedOnlyA =
                                        [length right .. length left - 1]
                                    expectedOnlyB =
                                        [length left .. length right - 1]
                                 in conjoin
                                        [ path === rootPath
                                        , map fst common === expectedCommon
                                        , map fst changed === expectedChanged
                                        , map fst onlyA === expectedOnlyA
                                        , map fst onlyB === expectedOnlyB
                                        , changedPathsAreArrayIndexes changed
                                        ]
                            other ->
                                counterexample ("unexpected array diff: " <> show other) False

        it "reports unequal generated scalar leaves as changed" $
            property $
                \(SmallOpenScalar left) (SmallOpenScalar right) ->
                    left /= right ==>
                        diffOpenValue left right
                            === DiffNode
                                rootPath
                                (DiffChanged (openValueJson left) (openValueJson right))

rootPath :: DiffPath
rootPath =
    DiffPath []

collapsedLeft :: OpenValue
collapsedLeft =
    OpenObject
        [
            ( "outputs"
            , OpenArray
                [ outputValue 10 100 300
                , outputValue 10 100 300
                , outputValue 11 101 300
                ]
            )
        ]

collapsedRight :: OpenValue
collapsedRight =
    OpenObject
        [
            ( "outputs"
            , OpenArray
                [ outputValue 20 200 400
                , outputValue 20 200 400
                , outputValue 21 201 400
                ]
            )
        ]

remainderLeft :: OpenValue
remainderLeft =
    OpenObject
        [
            ( "outputs"
            , OpenArray
                [ outputValue 10 100 300
                , outputValue 10 100 300
                , outputValue 11 101 300
                , OpenObject [("coin", OpenInteger 12)]
                ]
            )
        ]

remainderRight :: OpenValue
remainderRight =
    OpenObject
        [
            ( "outputs"
            , OpenArray
                [ outputValue 20 200 400
                , outputValue 20 200 400
                , outputValue 21 201 400
                , OpenObject [("coin", OpenInteger 22)]
                ]
            )
        ]

outputValue :: Integer -> Integer -> Integer -> OpenValue
outputValue coin datumIn datumOut =
    OpenObject
        [ ("coin", OpenInteger coin)
        ,
            ( "datum"
            , OpenObject
                [
                    ( "fields"
                    , OpenObject
                        [
                            ( "4"
                            , OpenObject
                                [
                                    ( "fields"
                                    , OpenObject
                                        [
                                            ( "0"
                                            , OpenObject
                                                [ ("2", OpenInteger datumIn)
                                                ]
                                            )
                                        ,
                                            ( "1"
                                            , OpenObject
                                                [ ("2", OpenInteger datumOut)
                                                ]
                                            )
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ]

openBytesJson :: Aeson.Value -> Aeson.Value
openBytesJson bytes =
    Aeson.object ["bytes" .= bytes]

newtype SmallOpenValue = SmallOpenValue OpenValue
    deriving stock (Show)

instance Arbitrary SmallOpenValue where
    arbitrary =
        SmallOpenValue <$> sized openValueGen

newtype SmallOpenObject = SmallOpenObject (Map.Map Text OpenValue)
    deriving stock (Show)

instance Arbitrary SmallOpenObject where
    arbitrary =
        SmallOpenObject <$> objectGen 3

newtype SmallOpenArray = SmallOpenArray [OpenValue]
    deriving stock (Show)

instance Arbitrary SmallOpenArray where
    arbitrary = do
        length' <- choose (0, 5)
        SmallOpenArray <$> vectorOf length' (openValueGen 3)

newtype SmallOpenScalar = SmallOpenScalar OpenValue
    deriving stock (Show)

instance Arbitrary SmallOpenScalar where
    arbitrary =
        SmallOpenScalar <$> scalarGen

openValueGen :: Int -> Gen OpenValue
openValueGen size
    | size <= 0 = scalarGen
    | otherwise =
        frequency
            [ (4, scalarGen)
            , (2, OpenObject <$> objectGen (size `div` 2))
            , (2, OpenArray <$> arrayGen (size `div` 2))
            ]

scalarGen :: Gen OpenValue
scalarGen =
    frequency
        [ (2, OpenInteger <$> choose (-20, 20))
        , (2, OpenText <$> textGen)
        , (1, OpenBytes <$> textGen)
        ]

objectGen :: Int -> Gen (Map.Map Text OpenValue)
objectGen childSize = do
    length' <- choose (0, 5)
    Map.fromList
        <$> vectorOf
            length'
            ((,) <$> keyGen <*> openValueGen childSize)

arrayGen :: Int -> Gen [OpenValue]
arrayGen childSize = do
    length' <- choose (0, 5)
    vectorOf length' (openValueGen childSize)

keyGen :: Gen Text
keyGen =
    elements ["a", "b", "c", "d", "e"]

textGen :: Gen Text
textGen =
    elements ["", "alpha", "beta", "00ff", "same"]

openValueSummary :: OpenValue -> Maybe Aeson.Value
openValueSummary (OpenInteger value) =
    Just (Aeson.Number (fromInteger value))
openValueSummary (OpenText value) =
    Just (Aeson.String value)
openValueSummary (OpenBytes value) =
    Just (openBytesJson (Aeson.String value))
openValueSummary (OpenObject _) =
    Nothing
openValueSummary (OpenArray _) =
    Nothing

openValueJson :: OpenValue -> Aeson.Value
openValueJson (OpenInteger value) =
    Aeson.Number (fromInteger value)
openValueJson (OpenText value) =
    Aeson.String value
openValueJson (OpenBytes value) =
    openBytesJson (Aeson.String value)
openValueJson (OpenObject fields) =
    Aeson.object
        [ Key.fromText key .= openValueJson value
        | (key, value) <- Map.toAscList fields
        ]
openValueJson (OpenArray values) =
    Aeson.toJSON (map openValueJson values)

changedPathsAreObjectKeys :: Map.Map Text DiffNode -> Property
changedPathsAreObjectKeys changed =
    conjoin
        [ path === DiffPath [key]
        | (key, DiffNode path _) <- Map.toAscList changed
        ]

changedPathsAreArrayIndexes :: [(Int, DiffNode)] -> Property
changedPathsAreArrayIndexes changed =
    conjoin
        [ path === DiffPath [Text.pack (show index)]
        | (index, DiffNode path _) <- changed
        ]
