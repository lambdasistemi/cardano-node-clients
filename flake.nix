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
        "github:input-output-hk/haskell.nix/ef52c36b9835c77a255befe2a20075ba71e3bfab";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix/c3d44f9e5d929e86a45a48246667ea25cd1f11df";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    iohkNix = {
      url =
        "github:input-output-hk/iohk-nix/f444d972c301ddd9f23eac4325ffcc8b5766eee9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/00c90c10812a98ef9680f4bfa269d42366d46d89";
      flake = false;
    };
    mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
    ghc-wasm-meta = {
      url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, haskellNix, hackageNix
    , iohkNix, CHaP, mkdocs, cardano-node, ghc-wasm-meta, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      flake = {
        lib.wasm = import ./nix/wasm { lib = nixpkgs.lib; };
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
            compiler-nix-name = "ghc9122";
            shell = {
              withHoogle = false;
              tools = {
                cabal = indexTool;
              };
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
          };
          components = project.hsPkgs.cardano-node-clients.components;
          checks = import ./nix/checks.nix {
            inherit pkgs components;
            cardanoNode = cardano-node.packages.${system}.cardano-node;
            src = ./.;
          };

          # Slice A smoke target: wasm32-wasi build of a trivial library
          # depending on cardano-ledger-binary via lib.wasm.mkCardanoLedgerWasm.
          # Slice A smoke target — pattern ported from /code/haskell-mts/nix/wasm.nix.
          # Two-phase FOD: dep download (hashed) → offline wasm32-wasi-cabal build.
          # dependenciesHash locked at the cborg-only smoke closure (no ledger
          # yet — ledger needs wasm32-built libsodium/secp256k1/blst + pkg-config,
          # tracked as follow-up).
          wasm-smoke = self.lib.wasm.mkCardanoLedgerWasm {
            inherit pkgs;
            ghcWasmMeta = ghc-wasm-meta.packages.${system}.all_9_12;
            chap = CHaP;
            src = ./nix/wasm/smoke;
            packages = [ "wasm-smoke" ];
            srpForks = [ "cborg" ];  # pre-fetch cborg fork for offline build
            dependenciesHash = "sha256-nSVMFUbwa2s7A1HDrCTm8RTnK6802ZTDvHkWpi1oFRo=";
          };
        in {
          packages.devnet-genesis = pkgs.runCommand "devnet-genesis" {} ''
            cp -r ${./e2e-test/genesis} $out
          '';
          packages.wasm-smoke = wasm-smoke;
          inherit checks;
          apps = import ./nix/apps.nix { inherit pkgs checks; };
          devShells.default = project.shell;
        };
    };
}
