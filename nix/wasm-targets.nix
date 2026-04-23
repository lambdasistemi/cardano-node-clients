# WASM smoke + ledger-smoke targets wired through self.lib.wasm.mkCardanoLedgerWasm.
#
# Smoke: cborg-only (no C libs); validates the infrastructure end-to-end.
# Ledger-smoke: full cardano-ledger-binary closure with wasm32-built libsodium +
#   secp256k1 + blst via pkg-config.
#
# Both targets are reproducible via the two-phase FOD pattern — dependenciesHash
# is locked per target. Bump the smoke/ledger-smoke cabal-wasm.project or
# forks.json → recompute by setting dependenciesHash = pkgs.lib.fakeHash and
# replacing with the hash Nix prints on the next build.
{ pkgs
, libWasm
, ghcWasmMeta
, wasiSdk
, chap
, smokeSrc
, ledgerSmokeSrc
}:
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
    srpForks = [
      "cborg"
      "plutus"
      "hs-memory"
      "foundation"
      "network"
      "double-conversion"
      "criterion-measurement"
      "haskell-lmdb-mock"
    ];
    withCLibs = true;
    dependenciesHash = "sha256-7dU3eySn+38cWtWHY5L5SNKXjiHNSn5ll1Sjrxr8zbY=";
  };
}
