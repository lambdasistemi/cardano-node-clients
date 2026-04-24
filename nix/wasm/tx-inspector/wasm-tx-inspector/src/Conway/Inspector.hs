{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

-- | Conway transaction inspector.
--
--   Decoder-only: no signature checking, no script evaluation, no fee
--   validation. The hard work (CBOR → Conway `Tx`) is delegated to the
--   upstream Haskell ledger packages; this module only projects the decoded
--   value into a lossy human-oriented JSON.
module Conway.Inspector
    ( inspect
    , InspectError(..)
    ) where

import qualified Cardano.Crypto.Hash            as Crypto
import qualified Cardano.Ledger.Address         as Addr
import qualified Cardano.Ledger.Api             as L
import qualified Cardano.Ledger.BaseTypes       as BaseTypes
import qualified Cardano.Ledger.Binary          as Binary
import qualified Cardano.Ledger.Coin            as Coin
import qualified Cardano.Ledger.Conway          as Conway
import           Cardano.Ledger.Core            (TxLevel (..))
import qualified Cardano.Ledger.Hashes          as Hashes
import qualified Cardano.Ledger.Mary.Value      as Mary
import qualified Cardano.Ledger.Plutus.Data     as PData
import qualified Cardano.Ledger.TxIn            as TxIn
import           Data.Aeson                     ((.=))
import qualified Data.Aeson                     as Aeson
import qualified Data.Aeson.Key                 as AesonKey
import qualified Data.Aeson.KeyMap              as KeyMap
import qualified Data.ByteString                as BS
import qualified Data.ByteString.Base16         as B16
import qualified Data.ByteString.Lazy           as BSL
import qualified Data.ByteString.Short          as SBS
import           Data.Foldable                  (toList)
import qualified Data.Map.Strict                as Map
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Lens.Micro                     ((^.))

data InspectError
    = MalformedHex String
    | MalformedCbor String
    deriving (Show)

-- | Hex → bytes → Conway tx → JSON.
inspect :: BS.ByteString -> Either InspectError Aeson.Value
inspect hexBytes = do
    raw <- hexDecode hexBytes
    tx  <- decodeConway (BSL.fromStrict raw)
    pure (renderTx tx)

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

renderTx :: L.Tx TopTx Conway.ConwayEra -> Aeson.Value
renderTx tx =
    let body        = tx ^. L.bodyTxL
        inputs      = toList (body ^. L.inputsTxBodyL)
        refIns      = toList (body ^. L.referenceInputsTxBodyL)
        outputs     = toList (body ^. L.outputsTxBodyL)
        fee         = body ^. L.feeTxBodyL
        vldt        = body ^. L.vldtTxBodyL
        mint        = body ^. L.mintTxBodyL
        certs       = toList (body ^. L.certsTxBodyL)
        withdrawals = body ^. L.withdrawalsTxBodyL
        reqSigners  = toList (body ^. L.reqSignerHashesTxBodyL)
    in
        Aeson.Object $ KeyMap.fromList
            [ "era"                   .= ("Conway" :: T.Text)
            , "decoder"               .= ("cardano-ledger-conway + cardano-ledger-binary (wasm32-wasi, GHC 9.12)" :: T.Text)
            , "fee_lovelace"          .= T.pack (show (Coin.unCoin fee))
            , "validity_interval"     .= validityJson vldt
            , "input_count"           .= length inputs
            , "reference_input_count" .= length refIns
            , "output_count"          .= length outputs
            , "cert_count"            .= length certs
            , "withdrawal_count"      .= withdrawalsCount withdrawals
            , "required_signer_count" .= length reqSigners
            , "inputs"                .= map txInJson inputs
            , "reference_inputs"      .= map txInJson refIns
            , "outputs"               .= map txOutJson outputs
            , "mint"                  .= multiAssetJson mint
            ]

validityJson :: L.ValidityInterval -> Aeson.Value
validityJson (L.ValidityInterval before hereafter) =
    Aeson.object
        [ "invalid_before"    .= renderSlot before
        , "invalid_hereafter" .= renderSlot hereafter
        ]
  where
    renderSlot :: BaseTypes.StrictMaybe BaseTypes.SlotNo -> Aeson.Value
    renderSlot BaseTypes.SNothing  = Aeson.Null
    renderSlot (BaseTypes.SJust s) = Aeson.toJSON (T.pack (show (BaseTypes.unSlotNo s)))

-- | Withdrawals are wrapped in a newtype; reach into the Map and count.
--   Ledger versions differ on the exact constructor / accessor; use Show
--   to bootstrap — replaceable with a proper accessor later.
withdrawalsCount :: L.Withdrawals -> Int
withdrawalsCount (L.Withdrawals m) = Map.size m

-- | Render a Conway TxOut with address, value (coin + assets), and datum.
txOutJson :: L.TxOut Conway.ConwayEra -> Aeson.Value
txOutJson txOut =
    let value              = txOut ^. L.valueTxOutL
        Mary.MaryValue c m = value
    in Aeson.object
        [ "address_hex"   .= T.decodeUtf8 (B16.encode (Addr.serialiseAddr (txOut ^. L.addrTxOutL)))
        , "coin_lovelace" .= T.pack (show (Coin.unCoin c))
        , "assets"        .= multiAssetJson m
        , "datum"         .= datumJson (txOut ^. L.datumTxOutL)
        ]

multiAssetJson :: Mary.MultiAsset -> Aeson.Value
multiAssetJson (Mary.MultiAsset m) =
    Aeson.Object $ KeyMap.fromList
        [ ( AesonKey.fromText (policyHex pid)
          , Aeson.Object $ KeyMap.fromList
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
    Aeson.object [ "kind" .= ("no_datum" :: T.Text) ]
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
