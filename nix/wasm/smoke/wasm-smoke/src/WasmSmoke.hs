-- | Smoke library proving the two-phase FOD WASM build pattern works
--   end-to-end: toolchain + truncated Hackage + CHaP + override-set forks
--   all reach the wasm32-wasi target.
--
--   The smoke deliberately depends on `cborg` (WASM-fixed fork pinned in
--   nix/wasm/forks.json) rather than `cardano-ledger-binary`, because the
--   latter transitively pulls `cardano-crypto-praos` which needs
--   pkg-config + wasm32-wasi-built libsodium/secp256k1/blst — C-library
--   infrastructure that is tracked as a follow-up task.
module WasmSmoke
    ( smokeRoundTrip
    ) where

import           Codec.CBOR.Decoding   (decodeInt)
import           Codec.CBOR.Encoding   (encodeInt)
import           Codec.CBOR.Read       (deserialiseFromBytes)
import           Codec.CBOR.Write      (toLazyByteString)
import qualified Data.ByteString.Lazy  as BSL

smokeRoundTrip :: Int -> Either String Int
smokeRoundTrip n =
    case deserialiseFromBytes decodeInt (toLazyByteString (encodeInt n)) of
        Left err      -> Left (show err)
        Right (_, n') -> Right n'
