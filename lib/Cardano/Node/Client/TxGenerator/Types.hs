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
    RefillResponse (..),
    FailureReason (..),

    -- * Failure-reason wire form
    failureReasonText,
) where

import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
 )
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

{- | Wire body of the @ready@ response.

'readyUpstream' surfaces the N2C reconnect supervisor's
view of the relay connection. Encoder invariant
(mirrors @utxo-indexer@ via PR #98): when
'readyUpstream' is 'UpstreamDisconnected' the wire
emits @ready=false@ regardless of 'readyReady', and
adds an @upstream@ object with the disconnect reason
and reconnect-attempt counters.
-}
data ReadyResponse = ReadyResponse
    { readyReady :: !Bool
    , readyIndexReady :: !Bool
    , readyFaucetUtxosKnown :: !Bool
    , readyUpstream :: !UpstreamStatus
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

-- | Wire body of the @transact@ response.
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

-- | Wire body of the @refill@ response.
data RefillResponse
    = RefillOk
        { rfOkTxId :: !Text
        -- ^ hex-encoded
        , rfOkFreshIndex :: !Word64
        , rfOkValueLovelace :: !Integer
        , rfOkAwaited :: !Bool
        }
    | RefillFail !FailureReason
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
    toJSON
        ReadyResponse
            { readyReady
            , readyIndexReady
            , readyFaucetUtxosKnown
            , readyUpstream
            } =
            object (baseFields <> upstreamField)
          where
            -- Defensively force ready=false whenever the
            -- supervisor reports a disconnected upstream.
            -- Mirrors the indexer's encoder shape so a
            -- consumer that already knows the indexer's
            -- @ready@ contract gets the same semantics.
            ready = case readyUpstream of
                UpstreamConnected -> readyReady
                UpstreamDisconnected{} -> False
            indexReady = case readyUpstream of
                UpstreamConnected -> readyIndexReady
                UpstreamDisconnected{} -> False
            baseFields =
                [ "ready" .= ready
                , "indexReady" .= indexReady
                , "faucetUtxosKnown" .= readyFaucetUtxosKnown
                ]
            upstreamField = case readyUpstream of
                UpstreamConnected -> []
                UpstreamDisconnected di ->
                    [ "upstream"
                        .= object
                            [ "status" .= ("disconnected" :: Text)
                            , "reason" .= diReason di
                            , "attempt" .= diAttempt di
                            , "sinceMs" .= diSinceMs di
                            ]
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

instance ToJSON RefillResponse where
    toJSON
        RefillOk
            { rfOkTxId
            , rfOkFreshIndex
            , rfOkValueLovelace
            , rfOkAwaited
            } =
            object
                [ "ok" .= True
                , "txId" .= rfOkTxId
                , "fresh_index" .= rfOkFreshIndex
                , "value_lovelace" .= rfOkValueLovelace
                , "awaited" .= rfOkAwaited
                ]
    toJSON (RefillFail r) =
        object
            [ "ok" .= False
            , "reason" .= failureReasonText r
            ]
