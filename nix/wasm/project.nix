# haskell.nix cabalProject' wrapping the WASM override set.
#
# This is the inner engine of mkCardanoLedgerWasm. The caller passes in the
# CHaP source (typically the flake input already present in their flake.nix)
# rather than having us re-fetch it, which keeps the builder hermetic and
# avoids `lib.fakeHash` gymnastics.
{ pkgs
, lib
, ghcWasmMeta
, chap           # Source tree of cardano-haskell-packages (typically a flake input, flake = false)
, src
, extraCabalProject ? ""
}:

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

  # GHC 9.10 is what IntersectMBO/cardano-api master's wasmShell uses
  # (all_9_10). GHC 9.12 clashes with basement/foundation forks due to
  # word64ToWord# in GHC.Prim. When the Jimbo4350/foundation fork is updated
  # to support 9.12, this can follow.
  compiler-nix-name = "ghc9102";

  # haskell.nix takes a single Hackage index-state; CHaP's own index-state
  # is carried by the cabal.project (see smoke/cabal.project or whatever the
  # caller supplies). Values source from forks.json — single source of truth.
  index-state = forks.indexState.hackage;

  inputMap = {
    "https://chap.intersectmbo.org/" = chap;
  };

  inherit cabalProjectLocal;

  modules = [
    overrides
    {
      reinstallableLibGhc = false;
    }
  ];

  shell = {
    withHoogle = false;
    tools = {
      cabal = "latest";
    };
    buildInputs = [ ghcWasmMeta ];
  };
}
