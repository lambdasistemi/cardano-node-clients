# WASM targets wired through self.lib.wasm.mkCardanoLedgerWasm.
#
# All three use the two-phase FOD pattern; dependenciesHash is locked per
# target. Bump forks.json / cabal-wasm.project → recompute by setting
# dependenciesHash = pkgs.lib.fakeHash and replacing with the hash Nix
# prints on the next build.
#
# - wasm-smoke        : cborg-only; validates infrastructure end-to-end
# - wasm-ledger-smoke : full ledger closure + wasm32-built C libs; prints a
#                       version reference
# - wasm-tx-inspector : real Conway tx decoder; reads hex on stdin, emits JSON
{ pkgs
, libWasm
, ghcWasmMeta
, wasiSdk
, chap
, smokeSrc
, ledgerSmokeSrc
, txInspectorSrc
}:
let
  # Full ledger override set + wasm32-built C libs — the superset both
  # wasm-ledger-smoke and wasm-tx-inspector need.
  fullLedgerForks = [
    "cborg"
    "plutus"
    "hs-memory"
    "foundation"
    "network"
    "double-conversion"
    "criterion-measurement"
    "haskell-lmdb-mock"
  ];
in
{
  wasm-smoke = libWasm.mkCardanoLedgerWasm {
    inherit pkgs ghcWasmMeta chap;
    src = smokeSrc;
    packages = [ "wasm-smoke" ];
    srpForks = [ "cborg" ];
    dependenciesHash = "sha256-nSVMFUbwa2s7A1HDrCTm8RTnK6802ZTDvHkWpi1oFRo=";
  };

  wasm-ledger-smoke = libWasm.mkCardanoLedgerWasm {
    inherit pkgs ghcWasmMeta wasiSdk chap;
    src = ledgerSmokeSrc;
    packages = [ "wasm-ledger-smoke" ];
    srpForks = fullLedgerForks;
    withCLibs = true;
    dependenciesHash = "sha256-7dU3eySn+38cWtWHY5L5SNKXjiHNSn5ll1Sjrxr8zbY=";
  };

  wasm-tx-inspector = libWasm.mkCardanoLedgerWasm {
    inherit pkgs ghcWasmMeta wasiSdk chap;
    src = txInspectorSrc;
    packages = [ "wasm-tx-inspector" ];
    srpForks = fullLedgerForks;
    withCLibs = true;
    # dependenciesHash distinct from wasm-ledger-smoke because the inspector
    # pulls additional Hackage tarballs (aeson, base16-bytestring, text,
    # microlens, ...) that expand the cabal cache.
    dependenciesHash = "sha256-KmY5jyyPc2NFXZSP133Tq6rQWp3d7STwT4O51h7Ukys=";
  };
}
