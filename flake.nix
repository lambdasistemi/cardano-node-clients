{
  description =
    "Haskell clients for Cardano node mini-protocols (N2C + N2N)";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix = {
      url =
        "github:input-output-hk/haskell.nix/8b447d7f57d62fab9249f79bb916bc891e29b9d0";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix/b6b4aa4bd699f743238da45c7f43da5a26a822f7";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    lintNixpkgs.url =
      "github:NixOS/nixpkgs/647e5c14cbd5067f44ac86b74f014962df460840";
    flake-parts.url = "github:hercules-ci/flake-parts";
    iohkNix = {
      url =
        "github:input-output-hk/iohk-nix/f444d972c301ddd9f23eac4325ffcc8b5766eee9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/887d73ce434831e3a67df48e070f4f979b3ac5a6";
      flake = false;
    };
    mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
  };

  outputs = inputs@{ self, nixpkgs, lintNixpkgs, flake-parts, haskellNix
    , hackageNix, iohkNix, CHaP, mkdocs, cardano-node, ... }:
    let
      imageTag =
        self.dirtyShortRev or self.shortRev or "unknown";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      flake = {
        inherit imageTag;
      };
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
          lintPkgs = import lintNixpkgs { inherit system; };
          indexState = "2026-02-17T10:15:41Z";
          indexTool = { index-state = indexState; };
          fix-libs = { lib, pkgs, ... }: {
            packages.cardano-crypto-praos.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.libsodium-vrf ] ];
            packages.cardano-crypto-class.components.library.pkgconfig =
              lib.mkForce
              [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
            packages.cardano-lmdb.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.lmdb ] ];
            packages.blockio-uring.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.liburing ] ];
            packages.cardano-ledger-binary.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-core.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-ledger-api.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-tx.components.library.doHaddock =
              lib.mkForce false;
          };
          project = pkgs.haskell-nix.cabalProject' {
            name = "cardano-node-clients";
            src = ./.;
            compiler-nix-name = "ghc9123";
            shell = {
              withHoogle = true;
              tools = {
                cabal = indexTool;
              };
              buildInputs = [
                lintPkgs.haskellPackages.cabal-fmt
                lintPkgs.haskellPackages.fourmolu
                lintPkgs.haskellPackages.hlint
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
          };
          components = project.hsPkgs.cardano-node-clients.components;
          checks = import ./nix/checks.nix {
            inherit pkgs components lintPkgs;
            cardanoNode = cardano-node.packages.${system}.cardano-node;
            src = ./.;
          };
          checkApps = import ./nix/apps.nix { inherit pkgs checks; };
        in {
          packages = {
            devnet-genesis = pkgs.runCommand "devnet-genesis" {} ''
              cp -r ${./e2e-test/genesis} $out
            '';
            cardano-tx-generator =
              components.exes.cardano-tx-generator;
            utxo-indexer = components.exes.utxo-indexer;
            cardano-tx-generator-image =
              import ./nix/docker-image.nix {
                inherit pkgs components imageTag;
              };
          };
          inherit checks;
          apps = checkApps // {
            cardano-tx-generator = {
              type = "app";
              program = "${
                  components.exes.cardano-tx-generator
                }/bin/cardano-tx-generator";
            };
            utxo-indexer = {
              type = "app";
              program = "${components.exes.utxo-indexer}/bin/utxo-indexer";
            };
          };
          devShells.default = project.shell;
        };
    };
}
