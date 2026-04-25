# Native haskell.nix cabalProject' for cardano-node-clients.
#
# Per-system — the caller supplies `pkgs` (already carrying haskell.nix +
# iohkNix overlays) plus the flake inputs it needs to thread through.
{ pkgs
, CHaP
, mkdocs
, cardano-node
, system
, src
}:

let
  indexState = "2026-02-17T10:15:41Z";
  indexTool = { index-state = indexState; };
  fix-libs = import ./fix-libs.nix;
in
pkgs.haskell-nix.cabalProject' {
  name = "cardano-node-clients";
  inherit src;
  compiler-nix-name = "ghc9122";
  shell = {
    withHoogle = false;
    tools = { cabal = indexTool; };
    buildInputs = [
      pkgs.haskellPackages.cabal-fmt
      pkgs.haskellPackages.fourmolu
      pkgs.haskellPackages.hlint
      pkgs.just
      pkgs.mkdocs
      pkgs.curl
      pkgs.cacert
      pkgs.lmdb
      pkgs.liburing
      mkdocs.packages.${system}.from-nixpkgs
      cardano-node.packages.${system}.cardano-node
    ];
    shellHook = ''
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    '';
  };
  modules = [ fix-libs ];
  inputMap = {
    "https://chap.intersectmbo.org/" = CHaP;
  };
}
