{
  description =
    "Haskell clients for Cardano node mini-protocols (N2C + N2N)";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix.url =
      "github:input-output-hk/haskell.nix/baa6a549ce876e9c44c494a12116f178f1becbe6";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    iohkNix = {
      url =
        "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/a46182e9c039737bf43cdb5286df49bbe0edf6fb";
      flake = false;
    };
    mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.5.4";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, haskellNix, iohkNix
    , CHaP, mkdocs, cardano-node, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            overlays = [
              iohkNix.overlays.crypto
              haskellNix.overlay
              iohkNix.overlays.haskell-nix-crypto
              iohkNix.overlays.cardano-lib
            ];
            inherit system;
          };
          indexState = "2025-12-07T00:00:00Z";
          indexTool = { index-state = indexState; };
          fix-libs = { lib, pkgs, ... }: {
            packages.cardano-crypto-praos.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.libsodium-vrf ] ];
            packages.cardano-crypto-class.components.library.pkgconfig =
              lib.mkForce
              [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
          };
          project = pkgs.haskell-nix.cabalProject' {
            name = "cardano-node-clients";
            src = ./.;
            compiler-nix-name = "ghc984";
            shell = {
              tools = {
                cabal = indexTool;
                cabal-fmt = indexTool;
                haskell-language-server = indexTool;
                fourmolu = indexTool;
                hlint = indexTool;
              };
              buildInputs = [
                pkgs.just
                pkgs.mkdocs
                pkgs.curl
                pkgs.cacert
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
          };
        in {
          packages.devnet-genesis = pkgs.runCommand "devnet-genesis" {} ''
            cp -r ${./e2e-test/genesis} $out
          '';
          devShells.default = project.shell;
        };
    };
}
