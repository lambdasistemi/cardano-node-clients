{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.Server
Description : NDJSON Unix-socket server for the indexer
License     : Apache-2.0

Listens on a Unix domain socket and serves the read
side of the indexer using newline-delimited JSON.

Wire (per @cardano-node-clients#78@):

@
REQ:  {"utxos_at": "<hex-of-address-bytes>"}
RESP: {"utxos": [{"txin": "<txid>#<ix>",
                  "txout": "<base16-cbor>"}, ...]}

REQ:  {"ready": null}
RESP: {"ready":<bool>, "tipSlot":<int|null>,
       "processedSlot":<int|null>, "slotsBehind":<int|null>}

REQ:  {"await": "<txid>#<ix>", "timeout_seconds": <int>}
RESP: {"slot":<int>, "blockHash":"<hex>", "txout":"<base16-cbor>"}
    | {"timeout": true}

REQ:  {"utxos_with_asset": {"policy_id": "<56 hex>",
                            "asset_name": "<0..64 hex>"}}
RESP: {"point": {"slot":<int>, "blockHash":"<hex>"},
       "utxos": [{"txin": "<txid>#<ix>",
                  "txout": "<base16-cbor>",
                  "quantity": "<decimal>",
                  "created": {"slot":<int>, "blockHash":"<hex>"},
                  "datum": {"kind":"none"}
                         | {"kind":"hash", "hash":"<hex>"}
                         | {"kind":"inline", "cbor":"<hex>"}}, ...],
       "network": {"magic":<int>},
       "coverage": {"start": "origin" | {"slot":<int>, "blockHash":"<hex>"},
                    "addresses": "all" | "filtered"},
       "freshness": {"status": "synced" | "catching_up"
                             | "disconnected" | "stale",
                     "tipSlot":<int|null>, "slotsBehind":<int|null>,
                     "secondsSinceProgress":<int>},
       "limits": ["address_filter" | "partial_history"
                 | "catching_up" | "disconnected" | "stale", ...]}
    | {"error": "invalid_asset_query", "detail": "<text>"}
    | {"error": "asset_index_unavailable",
       "reason": "rebuilding" | "absent" | "no_indexed_point"
               | "inconsistent"}
@

Each connection is a single request → single response →
EOF. A line no request accepts is answered with
@{"error": "malformed json"}@.

A successful asset answer states the 'Disclosure' the server was
given and a freshness sampled after its storage read and measured
from its own @point@ (see "Cardano.Node.Client.UTxOIndexer.Disclosure").
The two error answers carry no disclosure.

Address bytes are sent on the wire as hex. Bech32
parsing lives in the consumer (consumers either already
have raw bytes from the ledger or hex-encode them
explicitly before calling).
-}
module Cardano.Node.Client.UTxOIndexer.Server (
    -- * Server
    runServer,

    -- * Ready status
    ReadyStatus (..),
) where

import Cardano.Node.Client.UTxOIndexer.Disclosure (
    AddressCoverage (..),
    Coverage (..),
    CoverageStart (..),
    Disclosure (..),
    Freshness (..),
    FreshnessStatus (..),
    Limit (..),
    ReadyStatus (..),
    answerLimits,
    assessFreshness,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AssetMatch (..),
    AssetQueryUnavailable (..),
    AssetSnapshot (..),
    AwaitObservation (..),
    IndexerHandle (..),
 )
import Cardano.Node.Client.UTxOIndexer.TxOutView (
    DatumView (..),
    TxOutView (..),
    decodeTxOutView,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    AssetName,
    BlockHash (..),
    PolicyId,
    SlotNo (..),
    TxIn (..),
    TxOut (..),
    mkAssetName,
    mkPolicyId,
 )
import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Exception (bracket, finally, try)
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value,
    decodeStrict',
    encode,
    object,
    (.:),
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (getCurrentTime)
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    Socket,
    SocketType (Stream),
    accept,
    bind,
    close,
    listen,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import System.Directory (removeFile)
import System.IO.Error (isDoesNotExistError)

{- | Run the NDJSON server on @socketPath@ until killed
(by exception). Removes any stale socket file at
@socketPath@ first.

The accept loop forks a new thread per accepted
connection. Each handler reads one request line, writes
one response line, closes.
-}
runServer ::
    FilePath ->
    IndexerHandle ->
    Disclosure ->
    IO ReadyStatus ->
    IO ()
runServer socketPath idx disclosure getReady =
    bracket (openListenSocket socketPath) close $ \sock -> do
        listen sock 16
        let acceptLoop = do
                (conn, _) <- accept sock
                _ <- forkIO (handleConn idx disclosure getReady conn)
                acceptLoop
        acceptLoop

openListenSocket :: FilePath -> IO Socket
openListenSocket path = do
    removeIfPresent path
    sock <- socket AF_UNIX Stream 0
    bind sock (SockAddrUnix path)
    pure sock

removeIfPresent :: FilePath -> IO ()
removeIfPresent p = do
    r <- try (removeFile p)
    case r of
        Right () -> pure ()
        Left e
            | isDoesNotExistError e -> pure ()
            | otherwise -> ioError e

-- Per-connection handler ----------------------------------------------

handleConn ::
    IndexerHandle ->
    Disclosure ->
    IO ReadyStatus ->
    Socket ->
    IO ()
handleConn idx disclosure getReady conn = (`finally` close conn) $ do
    line <- recvLine conn
    case decodeStrict' line :: Maybe Request of
        Nothing ->
            sendLine conn (encode (errorResponse "malformed json"))
        Just (UtxosAt addr) -> do
            utxos <- snapshotAt idx addr
            sendLine conn (encode (UtxosResponse utxos))
        Just Ready -> do
            rs <- getReady
            sendLine conn (encode rs)
        Just (Await txIn mTimeout) -> do
            mObs <- awaitTxIn idx txIn mTimeout
            sendLine conn (encode (AwaitResponse mObs))
        Just (UtxosWithAsset policy name) -> do
            answer <- assetAnswer <$> assetUtxos idx policy name
            case answer of
                AssetRefused refusal -> sendLine conn (encode refusal)
                AssetFound point members -> do
                    -- Freshness is sampled after the storage read and
                    -- measured against that read's own point.
                    ready <- getReady
                    now <- getCurrentTime
                    let freshness = assessFreshness disclosure now ready point
                    sendLine conn $
                        encode $
                            object (members <> disclosureMembers disclosure freshness)
        Just (InvalidAssetQuery detail) ->
            sendLine conn (encode (invalidAssetQuery detail))

{- | Read up to and including the first @\n@. The line
itself is returned without the trailing newline.
-}
recvLine :: Socket -> IO ByteString
recvLine s = go BS.empty
  where
    go acc = do
        chunk <- Net.recv s 4096
        if BS.null chunk
            then pure (stripNewline acc)
            else case BS.elemIndex 0x0A chunk of
                Just i ->
                    let (hd, _) = BS.splitAt i chunk
                     in pure (stripNewline (acc <> hd))
                Nothing -> go (acc <> chunk)

stripNewline :: ByteString -> ByteString
stripNewline bs
    | not (BS.null bs) && BS.last bs == 0x0A =
        BS.init bs
    | otherwise = bs

-- | Send one JSON line followed by @\n@.
sendLine :: Socket -> LBS.ByteString -> IO ()
sendLine s payload =
    Net.sendAll s $
        LBS.toStrict $
            toLazyByteString $
                Builder.lazyByteString payload
                    <> Builder.char7 '\n'

-- Wire types ----------------------------------------------------------

data Request
    = UtxosAt !Address
    | Ready
    | Await !TxIn !(Maybe Int)
    | UtxosWithAsset !PolicyId !AssetName
    | -- | A @utxos_with_asset@ request that cannot be read, with
      -- the reason.
      InvalidAssetQuery !Text
    deriving stock (Eq, Show)

{- | The three original requests are tried first, so every line they
accept is answered exactly as before; a line carrying
@utxos_with_asset@ that none of them accepts is an asset query,
well-formed or not.
-}
instance FromJSON Request where
    parseJSON =
        Aeson.withObject "Request" $ \o ->
            (UtxosAt <$> (o .: "utxos_at" >>= parseHexAddress))
                <|> ( do
                        _ <- o .: "ready" :: Aeson.Parser Aeson.Value
                        pure Ready
                    )
                <|> ( do
                        s <- o .: "await"
                        txIn <- parseTxInWire s
                        mt <-
                            o Aeson..:? "timeout_seconds" ::
                                Aeson.Parser (Maybe Int)
                        pure (Await txIn mt)
                    )
                <|> ( either InvalidAssetQuery (uncurry UtxosWithAsset)
                        . parseAssetQuery
                        <$> o .: "utxos_with_asset"
                    )
      where
        parseHexAddress :: Text -> Aeson.Parser Address
        parseHexAddress t = case Base16.decode (Text.encodeUtf8 t) of
            Right bs -> pure (Address bs)
            Left err ->
                fail $ "utxos_at: invalid base16 — " <> err

parseTxInWire :: Text -> Aeson.Parser TxIn
parseTxInWire s =
    case Text.splitOn (Text.pack "#") s of
        [tidT, ixT] -> do
            tid <- case Base16.decode (Text.encodeUtf8 tidT) of
                Right bs
                    | BS.length bs == 32 -> pure bs
                Right _ -> fail "await: txid must be 32 bytes (64 hex)"
                Left err -> fail $ "await: invalid txid hex — " <> err
            ix <- case reads (Text.unpack ixT) of
                [(n, "")] | n >= 0 && n <= 65535 -> pure (fromInteger n)
                _ ->
                    fail
                        "await: ix must be a non-negative integer ≤ 65535"
            pure (TxIn tid ix)
        _ -> fail "await: expected \"<txid_hex>#<ix>\""

{- | Read the @utxos_with_asset@ value: an object with exactly
@policy_id@ (28 bytes) and @asset_name@ (0 to 32 bytes), both hex
in any case. 'Left' carries the detail of the
@invalid_asset_query@ answer.
-}
parseAssetQuery :: Value -> Either Text (PolicyId, AssetName)
parseAssetQuery = \case
    Aeson.Object q -> do
        case filter (`notElem` ["policy_id", "asset_name"]) (KeyMap.keys q) of
            [] -> Right ()
            unknown : _ ->
                Left ("unknown field " <> Key.toText unknown <> " in utxos_with_asset")
        policyBytes <- hexField "policy_id" q
        nameBytes <- hexField "asset_name" q
        policy <-
            maybe
                ( Left
                    ( "policy_id must be 28 bytes (56 hex digits), got "
                        <> byteCount policyBytes
                    )
                )
                Right
                (mkPolicyId policyBytes)
        name <-
            maybe
                ( Left
                    ( "asset_name must be at most 32 bytes (64 hex digits), got "
                        <> byteCount nameBytes
                    )
                )
                Right
                (mkAssetName nameBytes)
        Right (policy, name)
    _ ->
        Left "utxos_with_asset must be an object with policy_id and asset_name"
  where
    hexField k q = case KeyMap.lookup k q of
        Nothing -> Left ("missing field " <> Key.toText k)
        Just (Aeson.String t) -> case Base16.decode (Text.encodeUtf8 t) of
            Right bytes -> Right bytes
            Left err ->
                Left (Key.toText k <> " is not valid hex: " <> Text.pack err)
        Just _ -> Left (Key.toText k <> " must be a hex string")
    byteCount bytes = Text.pack (show (BS.length bytes)) <> " bytes"

newtype UtxosResponse = UtxosResponse [(TxIn, TxOut)]

instance ToJSON UtxosResponse where
    toJSON (UtxosResponse xs) =
        object ["utxos" .= map utxoEntry xs]
      where
        utxoEntry :: (TxIn, TxOut) -> Value
        utxoEntry (txin, txout) =
            object
                [ "txin" .= txInWire txin
                , "txout"
                    .= Text.decodeUtf8 (Base16.encode (unTxOut txout))
                ]

txInWire :: TxIn -> Text
txInWire (TxIn tid ix) =
    Text.decodeUtf8 (Base16.encode tid)
        <> "#"
        <> Text.pack (show ix)

errorResponse :: Text -> Value
errorResponse msg = object ["error" .= msg]

newtype AwaitResponse = AwaitResponse (Maybe AwaitObservation)

instance ToJSON AwaitResponse where
    toJSON (AwaitResponse Nothing) =
        object ["timeout" .= True]
    toJSON
        ( AwaitResponse
                ( Just
                        AwaitObservation
                            { aoSlot = SlotNo s
                            , aoBlockHash = BlockHash bh
                            , aoTxOut = txOut
                            }
                    )
            ) =
            object
                [ "slot" .= s
                , "blockHash" .= Text.decodeUtf8 (Base16.encode bh)
                , "txout" .= Text.decodeUtf8 (Base16.encode (unTxOut txOut))
                ]

-- | The answer to a @utxos_with_asset@ request that cannot be read.
invalidAssetQuery :: Text -> Value
invalidAssetQuery detail =
    object
        [ "error" .= ("invalid_asset_query" :: Text)
        , "detail" .= detail
        ]

{- | An asset answer before its disclosure: the v1 members of a
success with the snapshot's point, or a refusal sent as it is.
-}
data AssetAnswer
    = AssetFound !SlotNo ![Aeson.Pair]
    | AssetRefused !Value

{- | The answer to an asset query: the indexed point and every
holder, or @asset_index_unavailable@ naming why the store cannot
answer. A holder whose stored bytes no longer decode makes the
answer @inconsistent@: its datum is never made up.
-}
assetAnswer :: Either AssetQueryUnavailable AssetSnapshot -> AssetAnswer
assetAnswer = \case
    Left AssetIndexAbsent -> unavailable "absent"
    Left NoIndexedPoint -> unavailable "no_indexed_point"
    Left (AssetIndexInconsistent _) -> unavailable "inconsistent"
    Left AssetIndexRebuilding -> unavailable "rebuilding"
    Right AssetSnapshot{asPoint, asMatches} ->
        case traverse matchValue asMatches of
            Nothing -> unavailable "inconsistent"
            Just matches ->
                AssetFound
                    (fst asPoint)
                    [ "point" .= pointValue asPoint
                    , "utxos" .= matches
                    ]
  where
    unavailable :: Text -> AssetAnswer
    unavailable reason =
        AssetRefused $
            object
                [ "error" .= ("asset_index_unavailable" :: Text)
                , "reason" .= reason
                ]

{- | The four members every successful asset answer carries beside
its point and holders: @network@, @coverage@, @freshness@ and
@limits@.
-}
disclosureMembers :: Disclosure -> Freshness -> [Aeson.Pair]
disclosureMembers Disclosure{dsNetworkMagic, dsCoverage} freshness =
    [ "network" .= object ["magic" .= dsNetworkMagic]
    , "coverage" .= coverageValue dsCoverage
    , "freshness" .= freshnessValue freshness
    , "limits" .= map limitText (answerLimits dsCoverage freshness)
    ]

coverageValue :: Coverage -> Value
coverageValue Coverage{covStart, covAddresses} =
    object
        [ "start" .= case covStart of
            FromOrigin -> Aeson.String "origin"
            FromPoint slot hash -> pointValue (slot, hash)
        , "addresses" .= case covAddresses of
            AllAddresses -> "all" :: Text
            FilteredAddresses -> "filtered"
        ]

freshnessValue :: Freshness -> Value
freshnessValue
    Freshness
        { frStatus
        , frTipSlot
        , frSlotsBehind
        , frSecondsSinceProgress
        } =
        object
            [ "status" .= statusText frStatus
            , "tipSlot" .= fmap (\(SlotNo s) -> s) frTipSlot
            , "slotsBehind" .= frSlotsBehind
            , "secondsSinceProgress" .= frSecondsSinceProgress
            ]

statusText :: FreshnessStatus -> Text
statusText = \case
    Synced -> "synced"
    CatchingUp -> "catching_up"
    Disconnected -> "disconnected"
    Stale -> "stale"

limitText :: Limit -> Text
limitText = \case
    AddressFilterLimit -> "address_filter"
    PartialHistoryLimit -> "partial_history"
    CatchingUpLimit -> "catching_up"
    DisconnectedLimit -> "disconnected"
    StaleLimit -> "stale"

{- | One holder: its reference, its stored output bytes, quantity,
creation point, and the datum read from those same bytes. 'Nothing'
when the bytes do not decode.
-}
matchValue :: AssetMatch -> Maybe Value
matchValue
    AssetMatch
        { amTxIn
        , amTxOut
        , amQuantity
        , amCreatedSlot
        , amCreatedBlockHash
        } =
        case decodeTxOutView amTxOut of
            Left _ -> Nothing
            Right TxOutView{tovDatum} ->
                Just $
                    object
                        [ "txin" .= txInWire amTxIn
                        , "txout"
                            .= Text.decodeUtf8 (Base16.encode (unTxOut amTxOut))
                        , "quantity" .= Text.pack (show amQuantity)
                        , "created"
                            .= pointValue (amCreatedSlot, amCreatedBlockHash)
                        , "datum" .= datumValue tovDatum
                        ]

datumValue :: DatumView -> Value
datumValue = \case
    NoDatum -> object ["kind" .= ("none" :: Text)]
    DatumHash h ->
        object
            [ "kind" .= ("hash" :: Text)
            , "hash" .= Text.decodeUtf8 (Base16.encode h)
            ]
    InlineDatum cbor ->
        object
            [ "kind" .= ("inline" :: Text)
            , "cbor" .= Text.decodeUtf8 (Base16.encode cbor)
            ]

pointValue :: (SlotNo, BlockHash) -> Value
pointValue (SlotNo slot, BlockHash bh) =
    object
        [ "slot" .= slot
        , "blockHash" .= Text.decodeUtf8 (Base16.encode bh)
        ]
