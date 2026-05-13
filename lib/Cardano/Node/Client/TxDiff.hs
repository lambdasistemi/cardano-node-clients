{- |
Module      : Cardano.Node.Client.TxDiff
Description : Structural transaction diff primitives.

This module contains the render-independent diff core used by the transaction
diff feature. The central rule is equality first: paired values are compared
before any child projection is requested.
-}
module Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPlan (..),
    DiffPath (..),
    DiffProjection (..),
    OpenValue (..),
    diffOpenValue,
    diffWith,
) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

newtype DiffPath = DiffPath [Text]
    deriving stock (Eq, Show)

data DiffNode = DiffNode DiffPath DiffChange
    deriving stock (Eq, Show)

data DiffChange
    = DiffSame (Maybe Aeson.Value)
    | DiffChanged Aeson.Value Aeson.Value
    | DiffObject
        (Map Text (Maybe Aeson.Value))
        (Map Text DiffNode)
        (Map Text Aeson.Value)
        (Map Text Aeson.Value)
    | DiffArray
        [(Int, Maybe Aeson.Value)]
        [(Int, DiffNode)]
        [(Int, Aeson.Value)]
        [(Int, Aeson.Value)]
    deriving stock (Eq, Show)

data DiffPlan a = DiffPlan
    { diffEqual :: a -> a -> Bool
    , diffSummary :: a -> Maybe Aeson.Value
    , diffProject :: a -> DiffProjection a
    }

data DiffProjection a
    = DiffAtomic Aeson.Value
    | DiffObjectChildren (Map Text a)
    | DiffArrayChildren [a]

data OpenValue
    = OpenObject (Map Text OpenValue)
    | OpenArray [OpenValue]
    | OpenInteger Integer
    | OpenText Text
    | OpenBytes Text
    deriving stock (Eq, Show)

diffOpenValue :: OpenValue -> OpenValue -> DiffNode
diffOpenValue =
    diffWith openValuePlan

diffWith :: DiffPlan a -> a -> a -> DiffNode
diffWith plan =
    diffAt plan (DiffPath [])

diffAt :: DiffPlan a -> DiffPath -> a -> a -> DiffNode
diffAt plan path left right
    | diffEqual plan left right = DiffNode path (DiffSame (diffSummary plan left))
    | otherwise =
        case (diffProject plan left, diffProject plan right) of
            (DiffObjectChildren leftChildren, DiffObjectChildren rightChildren) ->
                diffObjectChildren plan path leftChildren rightChildren
            (DiffArrayChildren leftChildren, DiffArrayChildren rightChildren) ->
                diffArrayChildren plan path leftChildren rightChildren
            (leftProjection, rightProjection) ->
                DiffNode path $
                    DiffChanged
                        (projectionValue plan leftProjection)
                        (projectionValue plan rightProjection)

diffObjectChildren ::
    DiffPlan a ->
    DiffPath ->
    Map Text a ->
    Map Text a ->
    DiffNode
diffObjectChildren plan path leftChildren rightChildren =
    DiffNode path (DiffObject common changed onlyA onlyB)
  where
    keys =
        Map.keysSet leftChildren <> Map.keysSet rightChildren
    (common, changed, onlyA, onlyB) =
        foldr classify (Map.empty, Map.empty, Map.empty, Map.empty) keys

    classify key (commonAcc, changedAcc, onlyAAcc, onlyBAcc) =
        case (Map.lookup key leftChildren, Map.lookup key rightChildren) of
            (Just left, Just right)
                | diffEqual plan left right ->
                    ( Map.insert key (diffSummary plan left) commonAcc
                    , changedAcc
                    , onlyAAcc
                    , onlyBAcc
                    )
                | otherwise ->
                    ( commonAcc
                    , Map.insert key (diffAt plan (path </> key) left right) changedAcc
                    , onlyAAcc
                    , onlyBAcc
                    )
            (Just left, Nothing) ->
                ( commonAcc
                , changedAcc
                , Map.insert key (valueOf plan left) onlyAAcc
                , onlyBAcc
                )
            (Nothing, Just right) ->
                ( commonAcc
                , changedAcc
                , onlyAAcc
                , Map.insert key (valueOf plan right) onlyBAcc
                )
            (Nothing, Nothing) ->
                (commonAcc, changedAcc, onlyAAcc, onlyBAcc)

diffArrayChildren :: DiffPlan a -> DiffPath -> [a] -> [a] -> DiffNode
diffArrayChildren plan path leftChildren rightChildren =
    DiffNode path (DiffArray common changed onlyA onlyB)
  where
    paired =
        zip [0 :: Int ..] (zip leftChildren rightChildren)
    common =
        [ (index, diffSummary plan left)
        | (index, (left, right)) <- paired
        , diffEqual plan left right
        ]
    changed =
        [ (index, diffAt plan (path </> Text.pack (show index)) left right)
        | (index, (left, right)) <- paired
        , not (diffEqual plan left right)
        ]
    onlyA =
        [ (index, valueOf plan left)
        | (index, left) <-
            drop (length rightChildren) (zip [0 :: Int ..] leftChildren)
        ]
    onlyB =
        [ (index, valueOf plan right)
        | (index, right) <-
            drop (length leftChildren) (zip [0 :: Int ..] rightChildren)
        ]

valueOf :: DiffPlan a -> a -> Aeson.Value
valueOf plan =
    projectionValue plan . diffProject plan

projectionValue :: DiffPlan a -> DiffProjection a -> Aeson.Value
projectionValue _ (DiffAtomic value) =
    value
projectionValue plan (DiffObjectChildren children) =
    objectValue
        [ (key, valueOf plan child)
        | (key, child) <- Map.toAscList children
        ]
projectionValue plan (DiffArrayChildren children) =
    Aeson.toJSON (map (valueOf plan) children)

objectValue :: [(Text, Aeson.Value)] -> Aeson.Value
objectValue fields =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText key, value)
            | (key, value) <- fields
            ]

(</>) :: DiffPath -> Text -> DiffPath
DiffPath segments </> segment =
    DiffPath (segments <> [segment])

openValuePlan :: DiffPlan OpenValue
openValuePlan =
    DiffPlan
        { diffEqual = (==)
        , diffSummary = openValueSummary
        , diffProject = openValueProjection
        }

openValueSummary :: OpenValue -> Maybe Aeson.Value
openValueSummary (OpenInteger value) =
    Just (Aeson.Number (fromInteger value))
openValueSummary (OpenText value) =
    Just (Aeson.String value)
openValueSummary (OpenBytes value) =
    Just (Aeson.object ["bytes" .= value])
openValueSummary (OpenObject _) =
    Nothing
openValueSummary (OpenArray _) =
    Nothing

openValueProjection :: OpenValue -> DiffProjection OpenValue
openValueProjection (OpenObject fields) =
    DiffObjectChildren fields
openValueProjection (OpenArray values) =
    DiffArrayChildren values
openValueProjection (OpenInteger value) =
    DiffAtomic (Aeson.Number (fromInteger value))
openValueProjection (OpenText value) =
    DiffAtomic (Aeson.String value)
openValueProjection (OpenBytes value) =
    DiffAtomic (Aeson.object ["bytes" .= value])
