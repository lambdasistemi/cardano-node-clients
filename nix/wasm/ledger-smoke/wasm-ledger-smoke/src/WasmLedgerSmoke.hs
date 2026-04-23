-- | Smoke library exercising cardano-ledger-binary in the WASM target.
--
--   Referencing a Version value is enough to force the linker through
--   the full ledger-binary module graph.
module WasmLedgerSmoke
    ( smokeVersion
    ) where

import qualified Cardano.Ledger.Binary as L

smokeVersion :: L.Version
smokeVersion = L.natVersion @11
