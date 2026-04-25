{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Conway transaction inspector.

  Decoder-only: no signature checking, no script evaluation, no fee
  validation. The hard work (CBOR → Conway `Tx`) is delegated to the
  upstream Haskell ledger packages. Browser-facing calls use a small
  ledger-operation envelope so each UI interaction can go back through
  the ledger value instead of navigating a stale client-side JSON
  projection.
-}
module Conway.Inspector (
    inspect,
    runLedgerOperationInput,
    InspectError (..),
) where

import qualified Cardano.Crypto.Hash as Crypto
import qualified Cardano.Ledger.Address as Addr
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as BaseTypes
import qualified Cardano.Ledger.Binary as Binary
import qualified Cardano.Ledger.Coin as Coin
import qualified Cardano.Ledger.Conway as Conway
import Cardano.Ledger.Core (TxLevel (..))
import qualified Cardano.Ledger.Hashes as Hashes
import qualified Cardano.Ledger.Mary.Value as Mary
import qualified Cardano.Ledger.Plutus.Data as PData
import qualified Cardano.Ledger.TxIn as TxIn
import Control.Monad ((>=>))
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Short as SBS
import Data.Foldable (toList)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Lens.Micro ((^.))
import Text.Read (readMaybe)

data InspectError
    = MalformedHex String
    | MalformedCbor String
    | MalformedLedgerOperation String
    | UnknownLedgerOperation T.Text
    deriving (Show)

data LedgerOperationRequest = LedgerOperationRequest
    { lorTxCbor :: T.Text
    , lorOperation :: T.Text
    , lorPath :: [T.Text]
    }

instance Aeson.FromJSON LedgerOperationRequest where
    parseJSON = Aeson.withObject "LedgerOperationRequest" $ \o -> do
        txCbor <- o Aeson..: "tx_cbor"
        operation <- parseOperation o
        legacyPath <- o Aeson..:? "path" Aeson..!= []
        args <- o Aeson..:? "args" Aeson..!= Aeson.object []
        path <- parsePathArg args legacyPath
        pure
            LedgerOperationRequest
                { lorTxCbor = txCbor
                , lorOperation = normalizeOperation operation
                , lorPath = path
                }
      where
        parseOperation o = do
            maybeOp <- o Aeson..:? "op"
            case maybeOp of
                Just op -> pure op
                Nothing -> do
                    maybeMethod <- o Aeson..:? "method"
                    case maybeMethod of
                        Just method -> pure method
                        Nothing -> fail "missing required field: op"

        parsePathArg args legacyPath =
            case args of
                Aeson.Object obj ->
                    case KeyMap.lookup "path" obj of
                        Just pathValue -> Aeson.parseJSON pathValue
                        Nothing -> pure legacyPath
                _ -> pure legacyPath

        normalizeOperation "inspect" = "tx.inspect"
        normalizeOperation "browse" = "tx.browse"
        normalizeOperation op = op

-- | Hex → bytes → Conway tx → JSON.
inspect :: BS.ByteString -> Either InspectError Aeson.Value
inspect hexBytes = do
    tx <- decodeTx hexBytes
    pure (renderTx tx)

{- | Browser/runtime ledger operation. If stdin is not a JSON operation request,
  fall back to the legacy raw-CBOR inspection path used by CLI recipes.
-}
runLedgerOperationInput :: BS.ByteString -> Either InspectError Aeson.Value
runLedgerOperationInput input =
    case Aeson.eitherDecodeStrict' input of
        Right request -> runLedgerOperation request
        Left err
            | looksLikeJsonRequest input -> Left (MalformedLedgerOperation err)
            | otherwise -> inspect input

looksLikeJsonRequest :: BS.ByteString -> Bool
looksLikeJsonRequest input =
    case BS.dropWhile isJsonWhitespace input of
        bs | BS.null bs -> False
        bs -> BS.head bs == 0x7b
  where
    isJsonWhitespace c = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

runLedgerOperation :: LedgerOperationRequest -> Either InspectError Aeson.Value
runLedgerOperation request = do
    tx <- decodeTx (T.encodeUtf8 (lorTxCbor request))
    case lorOperation request of
        "tx.inspect" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "inspection" .= renderTx tx
                    , "browser" .= browserJson tx (lorPath request)
                    ]
        "tx.browse" ->
            pure $
                ledgerOperationResponse
                    (lorOperation request)
                    [ "browser" .= browserJson tx (lorPath request)
                    ]
        other -> Left (UnknownLedgerOperation other)

ledgerOperationResponse :: T.Text -> [(AesonKey.Key, Aeson.Value)] -> Aeson.Value
ledgerOperationResponse operation resultFields =
    Aeson.object
        [ "ledger_functional_layer" .= ("cardano-ledger-functional/v1" :: T.Text)
        , "op" .= operation
        , "result" .= Aeson.object resultFields
        ]

decodeTx ::
    BS.ByteString ->
    Either InspectError (L.Tx TopTx Conway.ConwayEra)
decodeTx =
    hexDecode >=> decodeConway . BSL.fromStrict

hexDecode :: BS.ByteString -> Either InspectError BS.ByteString
hexDecode bs =
    case B16.decode (BS.filter (not . isHexWhitespace) bs) of
        Left err -> Left (MalformedHex err)
        Right ok -> Right ok
  where
    isHexWhitespace c = c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d

decodeConway :: BSL.ByteString -> Either InspectError (L.Tx TopTx Conway.ConwayEra)
decodeConway bs =
    case Binary.decodeFullAnnotator (Binary.natVersion @11) "Tx" Binary.decCBOR bs of
        Left err -> Left (MalformedCbor (show err))
        Right tx -> Right tx

browserJson ::
    L.Tx TopTx Conway.ConwayEra ->
    [T.Text] ->
    Aeson.Value
browserJson tx requestedPath =
    let root = renderTx tx
        current = valueAt root requestedPath
        path = if current == Nothing then [] else requestedPath
        value = fromMaybe root current
        breadcrumbs = breadcrumbsFor path
        currentLabel = case reverse breadcrumbs of
            Aeson.Object crumb : _ ->
                case KeyMap.lookup "label" crumb of
                    Just (Aeson.String label) -> label
                    _ -> "tx"
            _ -> "tx"
        kind = kindOf value
     in Aeson.object
            [ "valid" .= True
            , "title" .= currentLabel
            , "subtitle"
                .= if kind == "array" || kind == "object"
                    then kind <> " / " <> valueSummary value
                    else kind
            , "currentPath" .= encodePath path
            , "currentJson" .= copyText value
            , "breadcrumbs" .= breadcrumbs
            , "rows" .= browserRows path value
            ]

valueAt :: Aeson.Value -> [T.Text] -> Maybe Aeson.Value
valueAt = foldl step . Just
  where
    step Nothing _ = Nothing
    step (Just (Aeson.Object o)) key =
        KeyMap.lookup (AesonKey.fromText key) o
    step (Just (Aeson.Array a)) key = do
        ix <- pathIndex key
        listAt ix (toList a)
    step _ _ = Nothing

listAt :: Int -> [a] -> Maybe a
listAt index xs
    | index < 0 = Nothing
    | otherwise = case drop index xs of
        value : _ -> Just value
        [] -> Nothing

pathIndex :: T.Text -> Maybe Int
pathIndex =
    stripPrefix "#" . T.unpack >=> readMaybe

kindOf :: Aeson.Value -> T.Text
kindOf Aeson.Null = "null"
kindOf (Aeson.Bool _) = "boolean"
kindOf (Aeson.Number _) = "number"
kindOf (Aeson.String _) = "string"
kindOf (Aeson.Array _) = "array"
kindOf (Aeson.Object _) = "object"

valueSummary :: Aeson.Value -> T.Text
valueSummary (Aeson.Array a) =
    plural (length (toList a)) "item"
valueSummary (Aeson.Object o) =
    plural (length (KeyMap.toList o)) "field"
valueSummary (Aeson.String t) =
    shortText t
valueSummary Aeson.Null =
    "null"
valueSummary value =
    copyText value

plural :: Int -> T.Text -> T.Text
plural n label =
    T.pack (show n) <> " " <> label <> if n == 1 then "" else "s"

shortText :: T.Text -> T.Text
shortText text =
    let limit = 56
     in if T.length text <= limit
            then text
            else T.take 40 text <> "..." <> T.takeEnd 12 text

copyText :: Aeson.Value -> T.Text
copyText (Aeson.String t) = t
copyText value =
    T.decodeUtf8 (BSL.toStrict (Aeson.encode value))

browserRows :: [T.Text] -> Aeson.Value -> [Aeson.Value]
browserRows parentPath (Aeson.Array a) =
    [ browserRow parentPath (T.pack ("#" <> show ix)) child
    | (ix, child) <- zip [0 :: Int ..] (toList a)
    ]
browserRows parentPath (Aeson.Object o) =
    [ browserRow parentPath (AesonKey.toText key) child
    | (key, child) <- KeyMap.toList o
    ]
browserRows _ _ =
    []

browserRow :: [T.Text] -> T.Text -> Aeson.Value -> Aeson.Value
browserRow parentPath label value =
    let path = parentPath <> [label]
     in Aeson.object
            [ "label" .= label
            , "path" .= encodePath path
            , "kind" .= kindOf value
            , "summary" .= valueSummary value
            , "copyValue" .= copyText value
            , "canDive" .= isContainer value
            ]

isContainer :: Aeson.Value -> Bool
isContainer (Aeson.Array _) = True
isContainer (Aeson.Object _) = True
isContainer _ = False

breadcrumbsFor :: [T.Text] -> [Aeson.Value]
breadcrumbsFor path =
    Aeson.object
        [ "label" .= ("tx" :: T.Text)
        , "path" .= encodePath []
        ]
        : [ Aeson.object
            [ "label" .= label
            , "path" .= encodePath (take n path)
            ]
          | (n, label) <- zip [1 :: Int ..] path
          ]

encodePath :: [T.Text] -> T.Text
encodePath path =
    T.decodeUtf8 (BSL.toStrict (Aeson.encode path))

renderTx :: L.Tx TopTx Conway.ConwayEra -> Aeson.Value
renderTx tx =
    let body = tx ^. L.bodyTxL
        inputs = toList (body ^. L.inputsTxBodyL)
        refIns = toList (body ^. L.referenceInputsTxBodyL)
        outputs = toList (body ^. L.outputsTxBodyL)
        fee = body ^. L.feeTxBodyL
        vldt = body ^. L.vldtTxBodyL
        mint = body ^. L.mintTxBodyL
        certs = toList (body ^. L.certsTxBodyL)
        withdrawals = body ^. L.withdrawalsTxBodyL
        reqSigners = toList (body ^. L.reqSignerHashesTxBodyL)
     in Aeson.Object $
            KeyMap.fromList
                [ "era" .= ("Conway" :: T.Text)
                , "decoder" .= ("cardano-ledger-conway + cardano-ledger-binary (wasm32-wasi, GHC 9.12)" :: T.Text)
                , "fee_lovelace" .= T.pack (show (Coin.unCoin fee))
                , "validity_interval" .= validityJson vldt
                , "input_count" .= length inputs
                , "reference_input_count" .= length refIns
                , "output_count" .= length outputs
                , "cert_count" .= length certs
                , "withdrawal_count" .= withdrawalsCount withdrawals
                , "required_signer_count" .= length reqSigners
                , "inputs" .= map txInJson inputs
                , "reference_inputs" .= map txInJson refIns
                , "outputs" .= map txOutJson outputs
                , "mint" .= multiAssetJson mint
                ]

validityJson :: L.ValidityInterval -> Aeson.Value
validityJson (L.ValidityInterval before hereafter) =
    Aeson.object
        [ "invalid_before" .= renderSlot before
        , "invalid_hereafter" .= renderSlot hereafter
        ]
  where
    renderSlot :: BaseTypes.StrictMaybe BaseTypes.SlotNo -> Aeson.Value
    renderSlot BaseTypes.SNothing = Aeson.Null
    renderSlot (BaseTypes.SJust s) = Aeson.toJSON (T.pack (show (BaseTypes.unSlotNo s)))

{- | Withdrawals are wrapped in a newtype; reach into the Map and count.
  Ledger versions differ on the exact constructor / accessor; use Show
  to bootstrap — replaceable with a proper accessor later.
-}
withdrawalsCount :: L.Withdrawals -> Int
withdrawalsCount (L.Withdrawals m) = Map.size m

-- | Render a Conway TxOut with address, value (coin + assets), and datum.
txOutJson :: L.TxOut Conway.ConwayEra -> Aeson.Value
txOutJson txOut =
    let value = txOut ^. L.valueTxOutL
        Mary.MaryValue c m = value
     in Aeson.object
            [ "address_hex" .= T.decodeUtf8 (B16.encode (Addr.serialiseAddr (txOut ^. L.addrTxOutL)))
            , "coin_lovelace" .= T.pack (show (Coin.unCoin c))
            , "assets" .= multiAssetJson m
            , "datum" .= datumJson (txOut ^. L.datumTxOutL)
            ]

multiAssetJson :: Mary.MultiAsset -> Aeson.Value
multiAssetJson (Mary.MultiAsset m) =
    Aeson.Object $
        KeyMap.fromList
            [ ( AesonKey.fromText (policyHex pid)
              , Aeson.Object $
                    KeyMap.fromList
                        [ ( AesonKey.fromText (assetNameHex an)
                          , Aeson.String (T.pack (show q))
                          )
                        | (an, q) <- Map.toList assetMap
                        ]
              )
            | (pid, assetMap) <- Map.toList m
            ]
  where
    policyHex :: Mary.PolicyID -> T.Text
    policyHex (Mary.PolicyID (Hashes.ScriptHash h)) =
        T.decodeUtf8 (B16.encode (Crypto.hashToBytes h))
    assetNameHex :: Mary.AssetName -> T.Text
    assetNameHex (Mary.AssetName sbs) = T.decodeUtf8 (B16.encode (SBS.fromShort sbs))

-- | Render TxOut datum state. The ledger's `Datum era` is three-cased.
datumJson :: PData.Datum Conway.ConwayEra -> Aeson.Value
datumJson PData.NoDatum =
    Aeson.object ["kind" .= ("no_datum" :: T.Text)]
datumJson (PData.DatumHash h) =
    Aeson.object
        [ "kind" .= ("datum_hash" :: T.Text)
        , "hash" .= T.decodeUtf8 (B16.encode (Crypto.hashToBytes (Hashes.extractHash h)))
        ]
datumJson (PData.Datum _) =
    Aeson.object
        [ "kind" .= ("inline_datum" :: T.Text)
        , "note" .= ("Plutus Data AST rendering deferred" :: T.Text)
        ]

txInJson :: TxIn.TxIn -> Aeson.Value
txInJson (TxIn.TxIn (TxIn.TxId safeHash) (BaseTypes.TxIx ix)) =
    Aeson.object
        [ "tx_id" .= T.decodeUtf8 (B16.encode (Crypto.hashToBytes (Hashes.extractHash safeHash)))
        , "index" .= fromEnum ix
        ]
