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
import qualified Cardano.Ledger.Api             as L
import qualified Cardano.Ledger.Binary          as Binary
import qualified Cardano.Ledger.Coin            as Coin
import qualified Cardano.Ledger.Conway          as Conway
import           Cardano.Ledger.Core            (TxLevel (..))
import qualified Cardano.Ledger.Hashes          as Hashes
import qualified Cardano.Ledger.BaseTypes       as BaseTypes
import qualified Cardano.Ledger.TxIn            as TxIn
import           Data.Aeson                     ((.=))
import qualified Data.Aeson                     as Aeson
import qualified Data.Aeson.KeyMap              as KeyMap
import qualified Data.ByteString                as BS
import qualified Data.ByteString.Base16         as B16
import qualified Data.ByteString.Lazy           as BSL
import           Data.Foldable                  (toList)
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
    let body    = tx ^. L.bodyTxL
        inputs  = toList (body ^. L.inputsTxBodyL)
        refIns  = toList (body ^. L.referenceInputsTxBodyL)
        outputs = toList (body ^. L.outputsTxBodyL)
        fee     = body ^. L.feeTxBodyL
    in
        Aeson.Object $ KeyMap.fromList
            [ "era"                   .= ("Conway" :: T.Text)
            , "decoder"               .= ("cardano-ledger-conway + cardano-ledger-binary (wasm32-wasi, GHC 9.12)" :: T.Text)
            , "fee_lovelace"          .= T.pack (show (Coin.unCoin fee))
            , "input_count"           .= length inputs
            , "reference_input_count" .= length refIns
            , "output_count"          .= length outputs
            , "inputs"                .= map txInJson inputs
            , "reference_inputs"      .= map txInJson refIns
            ]

txInJson :: TxIn.TxIn -> Aeson.Value
txInJson (TxIn.TxIn (TxIn.TxId safeHash) (BaseTypes.TxIx ix)) =
    Aeson.object
        [ "tx_id" .= T.decodeUtf8 (B16.encode (Crypto.hashToBytes (Hashes.extractHash safeHash)))
        , "index" .= fromEnum ix
        ]
