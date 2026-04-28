{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Types
Description : Wire types for the cardano-tx-generator daemon
License     : Apache-2.0

Aeson-encoded request and response types matching the
schemas in
@specs/034-cardano-tx-generator/contracts/control-wire.md@.
The schemas are the contract; these types are how the
'Cardano.Node.Client.TxGenerator.Server' module produces
and consumes them.
-}
module Cardano.Node.Client.TxGenerator.Types (
    -- * Requests
    Request (..),
    TransactRequest (..),
    RefillRequest (..),

    -- * Responses
    ReadyResponse (..),
    SnapshotResponse (..),
    TransactResponse (..),
    FailureReason (..),

    -- * Failure-reason wire form
    failureReasonText,
) where

import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value (Null),
    object,
    withObject,
    (.:),
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.Text (Text)
import Data.Word (Word64, Word8)

-- | Top-level request envelope.
data Request
    = ReqTransact !TransactRequest
    | ReqRefill !RefillRequest
    | ReqSnapshot
    | ReqReady
    deriving stock (Eq, Show)

-- | Body of the @transact@ request.
data TransactRequest = TransactRequest
    { txReqSeed :: !Word64
    , txReqFanout :: !Word8
    , txReqProbFresh :: !Double
    }
    deriving stock (Eq, Show)

-- | Body of the @refill@ request.
newtype RefillRequest = RefillRequest
    { rfReqSeed :: Word64
    }
    deriving stock (Eq, Show)

-- | Wire body of the @ready@ response.
data ReadyResponse = ReadyResponse
    { readyReady :: !Bool
    , readyIndexReady :: !Bool
    , readyFaucetUtxosKnown :: !Bool
    }
    deriving stock (Eq, Show)

-- | Wire body of the @snapshot@ response.
data SnapshotResponse = SnapshotResponse
    { snapPopulationSize :: !Word64
    , snapP10Lovelace :: !(Maybe Integer)
    , snapP50Lovelace :: !(Maybe Integer)
    , snapP90Lovelace :: !(Maybe Integer)
    , snapTipSlot :: !(Maybe Word64)
    , snapLastTxId :: !(Maybe Text)
    -- ^ Hex-encoded tx id of the last submitted tx, or
    -- 'Nothing' if no tx has been submitted yet.
    }
    deriving stock (Eq, Show)

-- | Wire body of the @transact@ / @refill@ response.
data TransactResponse
    = TransactOk
        { txOkTxId :: !Text
        -- ^ hex-encoded
        , txOkSrc :: !Word64
        , txOkDsts :: ![Word64]
        , txOkValuesLovelace :: ![Integer]
        , txOkFreshCount :: !Word64
        , txOkAwaited :: !Bool
        }
    | TransactFail !FailureReason
    deriving stock (Eq, Show)

{- | Discriminable failure categories per
@control-wire.md@ FR-015.
-}
data FailureReason
    = NoPickableSource
    | IndexNotReady
    | FaucetExhausted
    | FaucetNotKnown
    | SubmitRejected !Text
    deriving stock (Eq, Show)

-- | Wire-form text for a 'FailureReason'.
failureReasonText :: FailureReason -> Text
failureReasonText = \case
    NoPickableSource -> "no-pickable-source"
    IndexNotReady -> "index-not-ready"
    FaucetExhausted -> "faucet-exhausted"
    FaucetNotKnown -> "faucet-not-known"
    SubmitRejected msg -> "submit-rejected: " <> msg

-- ----------------------------------------------------------------------
-- FromJSON instances (request side)
-- ----------------------------------------------------------------------

instance FromJSON Request where
    parseJSON =
        withObject "Request" $ \o ->
            let keys =
                    filter
                        ( `elem`
                            ["transact", "refill", "snapshot", "ready"]
                        )
                        (map Key.toText (KeyMap.keys o))
             in case keys of
                    ["transact"] -> ReqTransact <$> o .: "transact"
                    ["refill"] -> ReqRefill <$> o .: "refill"
                    ["snapshot"] -> do
                        v <- o .: "snapshot"
                        ReqSnapshot <$ checkNull "snapshot" v
                    ["ready"] -> do
                        v <- o .: "ready"
                        ReqReady <$ checkNull "ready" v
                    [] ->
                        fail
                            "request envelope is empty; expected \
                            \one of {transact, refill, snapshot, \
                            \ready}"
                    _ ->
                        fail
                            "request must carry exactly one of \
                            \{transact, refill, snapshot, ready}"
      where
        checkNull :: String -> Aeson.Value -> Aeson.Parser ()
        checkNull _ Null = pure ()
        checkNull tag _ = fail (tag <> ": expected null")

instance FromJSON TransactRequest where
    parseJSON = withObject "transact" $ \o ->
        TransactRequest
            <$> o .: "seed"
            <*> o .: "fanout"
            <*> o .: "prob_fresh"

instance FromJSON RefillRequest where
    parseJSON = withObject "refill" $ \o ->
        RefillRequest <$> o .: "seed"

-- ----------------------------------------------------------------------
-- ToJSON instances (response side)
-- ----------------------------------------------------------------------

instance ToJSON ReadyResponse where
    toJSON ReadyResponse{readyReady, readyIndexReady, readyFaucetUtxosKnown} =
        object
            [ "ready" .= readyReady
            , "indexReady" .= readyIndexReady
            , "faucetUtxosKnown" .= readyFaucetUtxosKnown
            ]

instance ToJSON SnapshotResponse where
    toJSON
        SnapshotResponse
            { snapPopulationSize
            , snapP10Lovelace
            , snapP50Lovelace
            , snapP90Lovelace
            , snapTipSlot
            , snapLastTxId
            } =
            object
                [ "populationSize" .= snapPopulationSize
                , "p10_lovelace" .= snapP10Lovelace
                , "p50_lovelace" .= snapP50Lovelace
                , "p90_lovelace" .= snapP90Lovelace
                , "tipSlot" .= snapTipSlot
                , "lastTxId" .= snapLastTxId
                ]

instance ToJSON TransactResponse where
    toJSON
        TransactOk
            { txOkTxId
            , txOkSrc
            , txOkDsts
            , txOkValuesLovelace
            , txOkFreshCount
            , txOkAwaited
            } =
            object
                [ "ok" .= True
                , "txId" .= txOkTxId
                , "src" .= txOkSrc
                , "dsts" .= txOkDsts
                , "values_lovelace" .= txOkValuesLovelace
                , "fresh_count" .= txOkFreshCount
                , "awaited" .= txOkAwaited
                ]
    toJSON (TransactFail r) =
        object
            [ "ok" .= False
            , "reason" .= failureReasonText r
            ]
