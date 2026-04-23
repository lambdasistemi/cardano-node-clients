-- | Smoke library proving the WASM override set compiles the
--   `cardano-ledger-binary` closure end-to-end.
--
--   We only need the linker to drag the whole ledger-binary module
--   graph into the final .wasm; trivially exercising a version value is
--   enough to force the transitive closure.
module WasmSmoke
    ( smokeVersion
    ) where

import qualified Cardano.Ledger.Binary as L

-- | Reference a ledger-binary Version value so the module isn't
--   dead-code-eliminated.
smokeVersion :: L.Version
smokeVersion = L.natVersion @11
