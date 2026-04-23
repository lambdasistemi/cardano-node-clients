# haskell.nix cabalProject' wrapping the WASM override set.
#
# This is the inner engine of mkCardanoLedgerWasm. It accepts a source tree
# (the consumer's own Haskell package) and returns a configured project
# targeting wasm32-wasi with all forks applied.
{ pkgs, lib, ghcWasmMeta, src, extraCabalProject ? "" }:

let
  fragment = import ./cabal-project-fragment.nix { inherit lib; };
  overrides = import ./overrides.nix { inherit lib; };
  forks = fragment.forks;

  # Combined cabal.project appended to the consumer's own project.
  cabalProjectLocal = fragment.body + "\n" + extraCabalProject;
in
pkgs.haskell-nix.cabalProject' {
  name = "cardano-ledger-wasm";
  inherit src;

  compiler-nix-name = "ghc9122";

  # index-state lines are pulled from forks.json — the single source of truth.
  index-state = [
    "hackage.haskell.org ${forks.indexState.hackage}"
    "cardano-haskell-packages ${forks.indexState.chap}"
  ];

  inputMap = {
    "https://chap.intersectmbo.org/" = pkgs.fetchgit {
      url = "https://github.com/intersectmbo/cardano-haskell-packages";
      rev = "master";
      sha256 = lib.fakeHash; # NOTE: compute on first build via --sha256 comment pattern
    };
  };

  inherit cabalProjectLocal;

  modules = [
    overrides
    {
      # Cross-compilation target: wasm32-wasi.
      reinstallableLibGhc = false;
    }
  ];

  shell = {
    withHoogle = false;
    tools = {
      cabal = "latest";
    };
    buildInputs = [ ghcWasmMeta.wasm32-wasi-ghc-9_12 ];
  };
}
