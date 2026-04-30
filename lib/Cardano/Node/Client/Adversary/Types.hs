{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.Adversary.Types
Description : Wire types for the cardano-adversary daemon
License     : Apache-2.0

Aeson-encoded request and response types matching the schemas in
@specs/036-cardano-adversary/contracts/control-wire.md@. The
schemas are the contract; these types are how the
'Cardano.Node.Client.Adversary.Server' module produces and consumes
them.
-}
module Cardano.Node.Client.Adversary.Types (
    -- * Requests
    Request (..),
    ChainSyncFlapArgs (..),

    -- * Responses
    Response (..),
    ReadyDetails (..),
    ErrorReason (..),

    -- * Wire helpers
    errorReasonText,
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
import Data.Word (Word16, Word32, Word64)

{- | Top-level request envelope. One JSON object per line, single
request → single response.
-}
data Request
    = -- | Readiness probe: @{"ready": null}@.
      ReqReady
    | -- | Chain-sync flap: @{"chain_sync_flap": {"seed":..,"limit":..,"n_conns":..}}@.
      ReqChainSyncFlap !ChainSyncFlapArgs
    deriving stock (Eq, Show)

-- | Body of the @chain_sync_flap@ request.
data ChainSyncFlapArgs = ChainSyncFlapArgs
    { csfSeed :: !Word64
    -- ^ Sole source of randomness for this request.
    , csfLimit :: !Word32
    -- ^ Maximum blocks pulled per connection before disconnecting.
    , csfNConns :: !Word16
    -- ^ Number of concurrent N2N connections per request.
    }
    deriving stock (Eq, Show)

instance FromJSON ChainSyncFlapArgs where
    parseJSON = withObject "chain_sync_flap" $ \o ->
        ChainSyncFlapArgs
            <$> o .: "seed"
            <*> o .: "limit"
            <*> o .: "n_conns"

instance ToJSON ChainSyncFlapArgs where
    toJSON (ChainSyncFlapArgs seed limit nConns) =
        object
            [ "seed" .= seed
            , "limit" .= limit
            , "n_conns" .= nConns
            ]

instance FromJSON Request where
    parseJSON = withObject "request" $ \o ->
        case KeyMap.toList o of
            [("ready", Null)] -> pure ReqReady
            [("chain_sync_flap", body)] ->
                ReqChainSyncFlap <$> parseJSON body
            [(other, _)] ->
                fail $ "unknown request: " <> Key.toString other
            _ ->
                fail "request must have exactly one top-level key"

-- | Top-level response envelope. One JSON object per line.
data Response
    = -- | Successful @ready@ response.
      RespReady !ReadyDetails
    | -- | Endpoint reserved but logic not yet implemented (PR B).
      RespNotImplemented
    | -- | Wire-level error (malformed json, unknown key).
      RespError !ErrorReason
    deriving stock (Eq, Show)

-- | Structured details accompanying a 'RespReady' response.
data ReadyDetails = ReadyDetails
    { readyOverall :: !Bool
    -- ^ True iff every readiness component below is satisfied.
    , readyN2NHandshakeOk :: !Bool
    -- ^ True iff the daemon has completed its N2N handshake to
    -- at least one configured producer host. Always 'False' in
    -- PR B because no N2N work happens yet.
    , readyConfiguredHosts :: ![Text]
    -- ^ Producer hostnames the daemon is configured to target.
    }
    deriving stock (Eq, Show)

instance ToJSON ReadyDetails where
    toJSON (ReadyDetails overall n2n hosts) =
        object
            [ "ready" .= overall
            , "details"
                .= object
                    [ "n2nHandshakeOk" .= n2n
                    , "configuredHosts" .= hosts
                    ]
            ]

instance FromJSON ReadyDetails where
    parseJSON = withObject "ready response" $ \o -> do
        overall <- o .: "ready"
        details <- o .: "details"
        n2n <- details .: "n2nHandshakeOk"
        hosts <- details .: "configuredHosts"
        pure (ReadyDetails overall n2n hosts)

-- | Structured error reasons emitted on the wire.
data ErrorReason
    = -- | The bytes received before @\\n@ were not valid JSON.
      ErrMalformedJson
    | -- | The top-level JSON key is not a known endpoint name.
      ErrUnknownRequest
    deriving stock (Eq, Show)

errorReasonText :: ErrorReason -> Text
errorReasonText = \case
    ErrMalformedJson -> "malformed json"
    ErrUnknownRequest -> "unknown request"

instance ToJSON Response where
    toJSON = \case
        RespReady details -> toJSON details
        RespNotImplemented ->
            object ["ok" .= False, "reason" .= ("not-implemented" :: Text)]
        RespError reason ->
            object ["error" .= errorReasonText reason]

instance FromJSON Response where
    parseJSON v =
        Aeson.parseEither (parseJSON @ReadyDetails) v
            & either (const tryNotImplemented) (pure . RespReady)
      where
        tryNotImplemented = withObject "response" go v
        go o = case KeyMap.lookup "ok" o of
            Just (Aeson.Bool False) ->
                case KeyMap.lookup "reason" o of
                    Just (Aeson.String "not-implemented") ->
                        pure RespNotImplemented
                    _ -> tryError o
            _ -> tryError o
        tryError o = case KeyMap.lookup "error" o of
            Just (Aeson.String "malformed json") ->
                pure (RespError ErrMalformedJson)
            Just (Aeson.String "unknown request") ->
                pure (RespError ErrUnknownRequest)
            _ -> fail "unrecognised response shape"
        (&) :: a -> (a -> b) -> b
        x & f = f x
