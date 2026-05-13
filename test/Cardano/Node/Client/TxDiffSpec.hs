{-# LANGUAGE OverloadedLists #-}

module Cardano.Node.Client.TxDiffSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
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
