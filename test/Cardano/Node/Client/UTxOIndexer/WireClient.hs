{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.WireClient
Description : Test client for the indexer's NDJSON socket
License     : Apache-2.0

The client side of the @utxo-indexer@ socket as the wire tests speak
it: one request line per connection, the answer read to EOF under a
timeout (a held connection fails the test instead of hanging it),
request builders, and a strict reader for the @utxos_with_asset@
success answer that rejects any field the schema does not name: the
v1 members plus the four disclosure members of #201.
-}
module Cardano.Node.Client.UTxOIndexer.WireClient (
    -- * Transport
    withSocketServer,
    requestLine,

    -- * Requests
    encodeLine,
    assetLine,
    assetLineText,
    utxosAt,
    awaitPoint,

    -- * The v1 asset answer
    Answer (..),
    Match (..),
    holderOf,
    successAnswer,
    expectAnswer,
    askAsset,

    -- * Atomic batch answers
    BatchAnswer (..),
    BatchResult (..),
    batchAnswer,
    expectBatch,

    -- * Reading JSON
    decoded,
    objectWithKeys,
    textField,

    -- * Hex and TxIn text
    hex,
    hexBytes,
    txInOrder,
) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, bracket, try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    SocketType (Stream),
    close,
    connect,
    socket,
 )
import Network.Socket.ByteString qualified as Net
import System.Directory (doesPathExist)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)

-- * Transport

{- | Run @serve@ on a fresh socket path in a background thread, wait
until the server answers on it, run the client action with that path,
then stop the server.
-}
withSocketServer :: (FilePath -> IO ()) -> (FilePath -> IO a) -> IO a
withSocketServer serve action =
    withSystemTempDirectory "indexer-wire" $ \dir -> do
        let path = dir <> "/sock"
        bracket (forkIO (serve path)) killThread $ \_ -> do
            waitForSocket path
            action path

{- | Poll up to 5 s until the server answers a line on its socket. The
socket file appears when the server binds, before it listens; a
connection in between is refused, so the file alone is not readiness.
The probe is a line no request accepts, which every server answers at
once without touching its store or readiness.
-}
waitForSocket :: FilePath -> IO ()
waitForSocket path = go (500 :: Int)
  where
    go 0 = fail ("socket never answered at " <> path)
    go n = do
        present <- doesPathExist path
        answered <-
            if present
                then either (const False) (const True) <$> probe
                else pure False
        if answered then pure () else threadDelay 10_000 >> go (n - 1)
    probe :: IO (Either IOException ByteString)
    probe = try (requestLine path "not json")

{- | Send one request line (the newline is appended) and read the
answer to EOF. Fails after 150 s, which bounds the longest @await@
the tests send.
-}
requestLine :: FilePath -> ByteString -> IO ByteString
requestLine path line = do
    result <- timeout 150_000_000 exchange
    maybe (fail ("no EOF for request " <> show line)) pure result
  where
    exchange = bracket open close $ \s -> do
        Net.sendAll s (line <> "\n")
        readToEof s BS.empty
    open = do
        s <- socket AF_UNIX Stream 0
        connect s (SockAddrUnix path)
        pure s
    readToEof s acc = do
        chunk <- Net.recv s 4096
        if BS.null chunk then pure acc else readToEof s (acc <> chunk)

-- * Requests

encodeLine :: [(Key.Key, Aeson.Value)] -> ByteString
encodeLine = BSL.toStrict . Aeson.encode . Aeson.object . map (uncurry (.=))

-- | @{"utxos_with_asset": {"policy_id": .., "asset_name": ..}}@ from raw bytes.
assetLine :: ByteString -> ByteString -> ByteString
assetLine policy name = assetLineText (hex policy) (hex name)

-- | The asset request with the hex fields given verbatim.
assetLineText :: Text -> Text -> ByteString
assetLineText policy name =
    encodeLine
        [ "utxos_with_asset"
            .= Aeson.object ["policy_id" .= policy, "asset_name" .= name]
        ]

-- | Every @(txin, txout bytes)@ the daemon's @utxos_at@ lists for an address.
utxosAt :: FilePath -> ByteString -> IO [(Text, ByteString)]
utxosAt sock addr = do
    resp <- requestLine sock (encodeLine ["utxos_at" .= hex addr])
    case Aeson.decodeStrict' resp of
        Just (Aeson.Object o)
            | Just (Aeson.Array entries) <- KM.lookup "utxos" o ->
                traverse entry (foldr (:) [] entries)
        _ -> fail ("utxos_at answer: " <> show resp)
  where
    entry = \case
        Aeson.Object e
            | Just (Aeson.String t) <- KM.lookup "txin" e
            , Just (Aeson.String x) <- KM.lookup "txout" e ->
                (,) t <$> hexBytes x
        other -> fail ("utxos_at entry: " <> show other)

{- | The @(slot, blockHash)@ the daemon's @await@ reports for a TxIn,
waiting at most the given number of seconds; fails on a timeout.
-}
awaitPoint :: FilePath -> Text -> Int -> IO (Integer, Text)
awaitPoint sock txIn seconds = do
    resp <-
        requestLine sock $
            encodeLine ["await" .= txIn, "timeout_seconds" .= seconds]
    case Aeson.decodeStrict' resp of
        Just (Aeson.Object o)
            | Just (Aeson.Number s) <- KM.lookup "slot" o
            , Just (Aeson.String bh) <- KM.lookup "blockHash" o ->
                pure (round s, bh)
        _ -> fail ("await " <> show txIn <> ": " <> show resp)

-- * The v1 asset answer

data Answer = Answer
    { ansPoint :: (Integer, Text)
    -- ^ The indexed point: slot and block hash.
    , ansMatches :: [Match]
    }
    deriving stock (Eq, Show)

data Match = Match
    { mTxIn :: Text
    , mTxOut :: Text
    , mQuantity :: Text
    , mCreated :: (Integer, Text)
    , mDatum :: KM.KeyMap Aeson.Value
    }
    deriving stock (Eq, Show)

-- | The @(txin, quantity)@ of a match.
holderOf :: Match -> (Text, Text)
holderOf m = (mTxIn m, mQuantity m)

{- | Read a success answer, requiring exactly the v1 fields @point@
and @utxos@ beside the disclosure members @network@, @coverage@,
@freshness@ and @limits@ (read by the disclosure specs); per match
@txin@, @txout@, @quantity@ (a string), @created@ and @datum@
(@kind@ plus @hash@ or @cbor@ by kind).
-}
successAnswer :: ByteString -> Either String Answer
successAnswer resp = do
    top <-
        objectWithKeys
            ["coverage", "freshness", "limits", "network", "point", "utxos"]
            =<< decoded resp
    point <- slotAndHash =<< field "point" top
    entries <- case KM.lookup "utxos" top of
        Just (Aeson.Array xs) -> Right (foldr (:) [] xs)
        other -> Left ("utxos is not an array: " <> show other)
    Answer point <$> traverse match entries
  where
    match v = do
        o <- objectWithKeys ["created", "datum", "quantity", "txin", "txout"] v
        Match
            <$> textField "txin" o
            <*> textField "txout" o
            <*> textField "quantity" o
            <*> (slotAndHash =<< field "created" o)
            <*> (datumObject =<< field "datum" o)
    datumObject v = case v of
        Aeson.Object d -> case KM.lookup "kind" d of
            Just (Aeson.String "none") -> d <$ objectWithKeys ["kind"] v
            Just (Aeson.String "hash") -> d <$ objectWithKeys ["hash", "kind"] v
            Just (Aeson.String "inline") -> d <$ objectWithKeys ["cbor", "kind"] v
            other -> Left ("datum kind: " <> show other)
        other -> Left ("datum is not an object: " <> show other)
    slotAndHash v = do
        o <- objectWithKeys ["blockHash", "slot"] v
        slot <- case KM.lookup "slot" o of
            Just (Aeson.Number n) -> Right (round n)
            other -> Left ("slot is not a number: " <> show other)
        (,) slot <$> textField "blockHash" o

-- | 'successAnswer', failing the test with the raw answer.
expectAnswer :: ByteString -> IO Answer
expectAnswer resp =
    either
        (\why -> fail (why <> "; answer was " <> show resp))
        pure
        (successAnswer resp)

-- | Ask for one asset by raw policy and name bytes.
askAsset :: FilePath -> (ByteString, ByteString) -> IO Answer
askAsset sock (policy, name) =
    expectAnswer =<< requestLine sock (assetLine policy name)

-- * Reading JSON

decoded :: ByteString -> Either String Aeson.Value
decoded resp =
    maybe (Left "not a JSON value") Right (Aeson.decodeStrict' resp)

-- | An object with exactly the given keys.
objectWithKeys :: [Text] -> Aeson.Value -> Either String (KM.KeyMap Aeson.Value)
objectWithKeys keys = \case
    Aeson.Object o
        | sort (map Key.toText (KM.keys o)) == sort keys -> Right o
        | otherwise ->
            Left ("keys " <> show (KM.keys o) <> " instead of " <> show keys)
    other -> Left ("not an object: " <> show other)

field :: Text -> KM.KeyMap Aeson.Value -> Either String Aeson.Value
field k o =
    maybe (Left ("missing " <> show k)) Right (KM.lookup (Key.fromText k) o)

textField :: Text -> KM.KeyMap Aeson.Value -> Either String Text
textField k o =
    field k o >>= \case
        Aeson.String t -> Right t
        other -> Left (show k <> " is not a string: " <> show other)

-- * Hex and TxIn text

hex :: ByteString -> Text
hex = Text.decodeUtf8 . Base16.encode

hexBytes :: (MonadFail m) => Text -> m ByteString
hexBytes t = either fail pure (Base16.decode (Text.encodeUtf8 t))

-- | Ascending 'TxIn' order of wire text: id bytes, then numeric index.
txInOrder :: Text -> (ByteString, Int)
txInOrder t = case Text.splitOn "#" t of
    [tid, ix] ->
        ( either error id (Base16.decode (Text.encodeUtf8 tid))
        , read (Text.unpack ix)
        )
    _ -> error ("not a wire TxIn: " <> show t)

-- | One exact-key answer carrying a single full point and ordered rows.
data BatchAnswer = BatchAnswer
    { batchPoint :: (Integer, Text)
    , batchResults :: [BatchResult]
    }
    deriving stock (Eq, Show)

-- | Position and kind correlate each result, including duplicates.
data BatchResult = AddressRows [(Text, Text)] | AssetRows [Match]
    deriving stock (Eq, Show)

{- | Read the accepted batch schema independently, rejecting extra fields,
nonintegral slots and malformed members; no disclosure is accepted.
-}
batchAnswer :: ByteString -> Either String BatchAnswer
batchAnswer raw = do
    unlessLine
    top <- objectWithKeys ["point", "results"] =<< decoded raw
    p <- point =<< field "point" top
    rs <- array =<< field "results" top
    case rs of
        [] -> Left "results must be nonempty"
        _ -> BatchAnswer p <$> traverse result rs
  where
    unlessLine
        | not (BS.null raw) && BS.last raw == 10 && BS.count 10 raw == 1 = Right ()
        | otherwise = Left "batch must be exactly one LF-terminated response line"
    array (Aeson.Array xs) = Right (foldr (:) [] xs)
    array other = Left ("not an array: " <> show other)
    point v = do
        o <- objectWithKeys ["slot", "blockHash"] v
        s <- field "slot" o
        slot <- case Aeson.fromJSON s :: Aeson.Result Integer of
            Aeson.Success n | n >= 0 -> Right n
            _ -> Left ("slot must be a nonnegative integer: " <> show s)
        (,) slot <$> textField "blockHash" o
    result v@(Aeson.Object o)
        | KM.member "utxos_at" o = do
            e <- objectWithKeys ["utxos_at"] v
            xs <- array =<< field "utxos_at" e
            AddressRows <$> traverse address xs
        | KM.member "utxos_with_asset" o = do
            e <- objectWithKeys ["utxos_with_asset"] v
            xs <- array =<< field "utxos_with_asset" e
            AssetRows <$> traverse asset xs
    result other = Left ("unknown result: " <> show other)
    address v = do
        o <- objectWithKeys ["txin", "txout"] v
        (,) <$> textField "txin" o <*> textField "txout" o
    asset v = do
        o <- objectWithKeys ["txin", "txout", "quantity", "created", "datum"] v
        Match
            <$> textField "txin" o
            <*> textField "txout" o
            <*> textField "quantity" o
            <*> (point =<< field "created" o)
            <*> (datum =<< field "datum" o)
    datum v = do
        o <- case v of
            Aeson.Object d -> Right d
            _ -> Left "datum is not an object"
        kind <- textField "kind" o
        case kind of
            "none" -> objectWithKeys ["kind"] v
            "hash" -> textField "hash" o >> objectWithKeys ["kind", "hash"] v
            "inline" -> textField "cbor" o >> objectWithKeys ["kind", "cbor"] v
            _ -> Left ("unknown datum kind: " <> show kind)

-- | Assert successful decoding with the actual response in the mismatch.
expectBatch :: ByteString -> IO BatchAnswer
expectBatch raw = either (fail . (<> "; actual response: " <> show raw)) pure (batchAnswer raw)
