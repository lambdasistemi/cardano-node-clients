# Public API surface for lib.wasm.
#
# Contract: see ../../specs/033-wasm-ledger-inspector/contracts/nix-api.md
#
# Module is system-agnostic (only nixpkgs `lib` is needed to build strings).
# Per-system `pkgs` + `ghcWasmMeta` flow in through `mkCardanoLedgerWasm`'s
# own argument list, matching the documented contract.
{ lib }:

let
  fragment = import ./cabal-project-fragment.nix { inherit lib; };
in
{
  cabalWasmProjectFragment = fragment.stanza;

  haskellWasmOverlay = import ./overrides.nix { inherit lib; };

  mkCardanoLedgerWasm =
    { pkgs
    , ghcWasmMeta
    , chap
    , src
    , packages
    , extraCabalProject ? ""
    , indexState ? null
    , ghcVersion ? "9.12"
    }:
    (import ./mkCardanoLedgerWasm.nix {
      inherit pkgs lib ghcWasmMeta chap;
    }) {
      inherit src packages extraCabalProject indexState ghcVersion;
    };

  forks = fragment.forks;
}
