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
@

Each connection is a single request → single response →
EOF; the @await@ streaming primitive lands in a separate
patch.

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

import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    AwaitObservation (..),
    IndexerHandle (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
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
import Data.Word (Word64)
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

{- | Sync-readiness snapshot used for the @ready@
endpoint. Mirrors @cardano-utxo-csmt@'s @ReadyResponse@
field shape (@ready@/@tipSlot@/@processedSlot@/
@slotsBehind@) so consumers wired against either
daemon get the same JSON.

The 'rsUpstream' field surfaces the reconnect supervisor's
view of the upstream chain-sync session. Invariant:
'rsUpstream' = 'UpstreamDisconnected' implies
'rsReady' is 'False'. The 'ToJSON' encoder enforces this
defensively on the wire — 'rsReady' is set to 'False'
whenever 'rsUpstream' is in the disconnected state, even
if the producer's 'TVar' lags. Encoding stays
backwards-compatible: the @upstream@ field is omitted
entirely when the supervisor reports
'UpstreamConnected'. See
@specs\/035-indexer-n2c-reconnect\/contracts\/control-wire.md@.
-}
data ReadyStatus = ReadyStatus
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe SlotNo)
    , rsProcessedSlot :: !(Maybe SlotNo)
    , rsSlotsBehind :: !(Maybe Word64)
    , rsUpstream :: !UpstreamStatus
    }
    deriving stock (Eq, Show)

instance ToJSON ReadyStatus where
    toJSON
        ReadyStatus
            { rsReady
            , rsTipSlot
            , rsProcessedSlot
            , rsSlotsBehind
            , rsUpstream
            } =
            object (baseFields <> upstreamField)
          where
            -- Defensively force ready=False whenever the
            -- supervisor reports a disconnected upstream.
            ready = case rsUpstream of
                UpstreamConnected -> rsReady
                UpstreamDisconnected _ -> False
            unSlotNo (SlotNo s) = s
            baseFields =
                [ "ready" .= ready
                , "tipSlot" .= fmap unSlotNo rsTipSlot
                , "processedSlot" .= fmap unSlotNo rsProcessedSlot
                , "slotsBehind" .= rsSlotsBehind
                ]
            upstreamField = case rsUpstream of
                UpstreamConnected -> []
                UpstreamDisconnected di ->
                    [ "upstream"
                        .= object
                            [ "status" .= ("disconnected" :: Text)
                            , "reason" .= diReason di
                            , "attempt" .= diAttempt di
                            , "elapsedMs" .= diSinceMs di
                            ]
                    ]

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
    IO ReadyStatus ->
    IO ()
runServer socketPath idx getReady =
    bracket (openListenSocket socketPath) close $ \sock -> do
        listen sock 16
        let acceptLoop = do
                (conn, _) <- accept sock
                _ <- forkIO (handleConn idx getReady conn)
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
    IO ReadyStatus ->
    Socket ->
    IO ()
handleConn idx getReady conn = (`finally` close conn) $ do
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
    deriving stock (Eq, Show)

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
