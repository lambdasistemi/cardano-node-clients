{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxDiff.Resolver.Web2
Description : tx-diff resolver backed by a Blockfrost-style web2 endpoint
License     : Apache-2.0

A 'Resolver' that fetches each distinct referenced transaction's CBOR
from a Blockfrost-compatible web2 provider, decodes it as a Conway
transaction, and indexes the referenced 'TxIx' to recover the resolved
'TxOut'. Inputs whose referenced transaction cannot be fetched or
decoded, or whose 'TxIx' is out of range, are silently skipped: the
resolver chain will then report them as unresolved for diagnostics.

The HTTP call is pluggable via 'Web2FetchTx' so unit tests can inject
canned responses without standing up a fake HTTP server. The production
implementation 'httpFetchTx' uses 'http-client' + 'http-client-tls'.
-}
module Cardano.Node.Client.TxDiff.Resolver.Web2 (
    Web2FetchTx,
    Web2FetchError (..),
    Web2Config (..),
    web2Resolver,
    httpFetchTx,
) where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Lens.Micro ((^.))
import Network.HTTP.Client (
    Manager,
    Request (..),
    httpLbs,
    parseRequest,
    responseBody,
    responseStatus,
 )
import Network.HTTP.Types.Status (statusCode)

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (
    Annotator,
    Decoder,
    decCBOR,
    decodeFullAnnotatorFromHexText,
    natVersion,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxDiff.Resolver (Resolver (..))

-- | Why a single web2 fetch failed.
data Web2FetchError
    = Web2FetchHttpError Text
    | Web2FetchDecodeError Text
    deriving stock (Eq, Show)

{- | Pluggable per-transaction fetcher. Implementations are given the
hex-encoded 'TxId' and return either an error or the raw CBOR bytes of
that transaction.
-}
type Web2FetchTx =
    Text -> IO (Either Web2FetchError ByteString)

-- | Configuration for a Blockfrost-style web2 resolver.
data Web2Config = Web2Config
    { web2ResolverName :: Text
    -- ^ Diagnostic name; defaults to @"web2"@ for callers that do not
    -- have a reason to override.
    , web2Fetch :: Web2FetchTx
    }

{- | Build a web2 'Resolver' from a configured fetcher. The resolver
issues one 'Web2FetchTx' call per *distinct* requested 'TxId', then
indexes each requested 'TxIn' into the decoded transaction's outputs.
-}
web2Resolver :: Web2Config -> Resolver
web2Resolver Web2Config{web2ResolverName, web2Fetch} =
    Resolver
        { resolverName = web2ResolverName
        , resolveInputs = \inputs -> do
            let txIds = Set.fromList [txId | TxIn txId _ <- toList inputs]
            fetched <-
                Map.fromList
                    <$> traverse fetchOne (Set.toAscList txIds)
            pure (resolveInputsFromFetched fetched inputs)
        }
  where
    fetchOne :: TxId -> IO (TxId, Either Web2FetchError ConwayTx)
    fetchOne txId = do
        result <- web2Fetch (txIdHex txId)
        pure
            ( txId
            , result >>= decodeFetched
            )

-- | Merge fetched transactions with the requested input set.
resolveInputsFromFetched ::
    Map TxId (Either Web2FetchError ConwayTx) ->
    Set TxIn ->
    Map TxIn (TxOut ConwayEra)
resolveInputsFromFetched fetched inputs =
    Map.fromList
        [ (txIn, txOut)
        | txIn@(TxIn txId (TxIx ix)) <- toList inputs
        , Just (Right tx) <- [Map.lookup txId fetched]
        , Just txOut <- [outputAtIndex tx (fromIntegral ix)]
        ]

outputAtIndex :: ConwayTx -> Int -> Maybe (TxOut ConwayEra)
outputAtIndex tx ix =
    let outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
     in case drop ix outputs of
            (out : _) -> Just out
            [] -> Nothing

decodeFetched :: ByteString -> Either Web2FetchError ConwayTx
decodeFetched bytes =
    first (Web2FetchDecodeError . Text.pack . show) $
        decodeFullAnnotatorFromHexText
            (natVersion @11)
            "tx-diff web2 resolved transaction"
            (decCBOR :: forall s. Decoder s (Annotator ConwayTx))
            (Text.decodeUtf8 (hexEncode bytes))

hexEncode :: ByteString -> ByteString
hexEncode = Base16.encode

txIdHex :: TxId -> Text
txIdHex (TxId safeHash) =
    Text.decodeUtf8 (hexEncode (hashToBytes (extractHash safeHash)))

{- | Production 'Web2FetchTx' that performs an HTTP GET against
@\<baseUrl\>/txs/\<txid\>/cbor@ and parses the response as JSON
@{"cbor":"\<hex\>"}@.

The optional API key is sent as a @project_id@ header (Blockfrost
convention).
-}
httpFetchTx ::
    Manager ->
    -- | Base URL, e.g. @"https://cardano-mainnet.blockfrost.io/api/v0"@
    Text ->
    -- | Optional Blockfrost @project_id@
    Maybe Text ->
    Web2FetchTx
httpFetchTx manager baseUrl apiKey txIdHexText = do
    let url = Text.unpack baseUrl <> "/txs/" <> Text.unpack txIdHexText <> "/cbor"
    requestResult <-
        try @SomeException (parseRequest url)
    case requestResult of
        Left err ->
            pure
                . Left
                . Web2FetchHttpError
                $ "bad URL "
                    <> Text.pack url
                    <> ": "
                    <> Text.pack (show err)
        Right req0 -> do
            let req =
                    req0
                        { requestHeaders =
                            requestHeaders req0
                                <> [ ("project_id", Text.encodeUtf8 key)
                                   | Just key <- [apiKey]
                                   ]
                        }
            httpResult <- try @SomeException (httpLbs req manager)
            case httpResult of
                Left err ->
                    pure
                        . Left
                        . Web2FetchHttpError
                        $ "GET "
                            <> Text.pack url
                            <> " failed: "
                            <> Text.pack (show err)
                Right response
                    | statusCode (responseStatus response) >= 400 ->
                        pure
                            . Left
                            . Web2FetchHttpError
                            $ "GET "
                                <> Text.pack url
                                <> " returned HTTP "
                                <> Text.pack (show (statusCode (responseStatus response)))
                    | otherwise ->
                        pure $
                            parseBlockfrostCborResponse (responseBody response)

parseBlockfrostCborResponse ::
    LBS.ByteString -> Either Web2FetchError ByteString
parseBlockfrostCborResponse body =
    case Aeson.eitherDecode body of
        Left err ->
            Left
                . Web2FetchDecodeError
                . Text.pack
                $ "expected {\"cbor\":\"...\"}: " <> err
        Right envelope ->
            case Base16.decode (Text.encodeUtf8 (blockfrostCborHex envelope)) of
                Left hexErr ->
                    Left
                        . Web2FetchDecodeError
                        . Text.pack
                        $ "could not hex-decode cbor field: " <> hexErr
                Right raw ->
                    Right raw

newtype BlockfrostCborResponse = BlockfrostCborResponse
    { blockfrostCborHex :: Text
    }

instance Aeson.FromJSON BlockfrostCborResponse where
    parseJSON =
        Aeson.withObject "BlockfrostCborResponse" $ \value ->
            BlockfrostCborResponse <$> value Aeson..: "cbor"
