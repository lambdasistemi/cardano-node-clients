{
  description = "Haskell clients for Cardano node mini-protocols (N2C + N2N)";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  inputs = {
    haskellNix = {
      url = "github:input-output-hk/haskell.nix/ef52c36b9835c77a255befe2a20075ba71e3bfab";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix/c3d44f9e5d929e86a45a48246667ea25cd1f11df";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix/f444d972c301ddd9f23eac4325ffcc8b5766eee9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/00c90c10812a98ef9680f4bfa269d42366d46d89";
      flake = false;
    };
    mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
    ghc-wasm-meta = {
      url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
    };
    purescript-overlay = {
      url = "github:paolino/purescript-overlay/fix/remove-nodePackages";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mkSpagoDerivation = {
      url = "github:jeslie0/mkSpagoDerivation";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, haskellNix, iohkNix, CHaP
    , mkdocs, cardano-node, ghc-wasm-meta, purescript-overlay
    , mkSpagoDerivation, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];

      flake = {
        lib.wasm = import ./nix/wasm { lib = nixpkgs.lib; };
      };

      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              iohkNix.overlays.crypto
              haskellNix.overlay
              iohkNix.overlays.haskell-nix-crypto
              iohkNix.overlays.cardano-lib
            ];
          };

          project = import ./nix/project.nix {
            inherit pkgs CHaP mkdocs cardano-node system;
            src = ./.;
          };
          components = project.hsPkgs.cardano-node-clients.components;
          checks = import ./nix/checks.nix {
            inherit pkgs components;
            cardanoNode = cardano-node.packages.${system}.cardano-node;
            src = ./.;
          };
          apps = import ./nix/apps.nix { inherit pkgs checks; };

          wasmTargets = import ./nix/wasm-targets.nix {
            inherit pkgs;
            libWasm      = self.lib.wasm;
            ghcWasmMeta  = ghc-wasm-meta.packages.${system}.all_9_12;
            wasiSdk      = ghc-wasm-meta.packages.${system}.wasi-sdk;
            chap         = CHaP;
            smokeSrc        = ./nix/wasm/smoke;
            ledgerSmokeSrc  = ./nix/wasm/ledger-smoke;
            txInspectorSrc  = ./nix/wasm/tx-inspector;
          };

          tx-inspector-ui = import ./nix/wasm-ui.nix {
            inherit system nixpkgs purescript-overlay mkSpagoDerivation;
            wasmArtifact     = wasmTargets.wasm-tx-inspector;
            wasmArtifactName = "wasm-tx-inspector";
            src              = ./docs/inspector;
          };
        in
        {
          packages = {
            devnet-genesis = pkgs.runCommand "devnet-genesis" { } ''
              cp -r ${./e2e-test/genesis} $out
            '';
            inherit (wasmTargets) wasm-smoke wasm-ledger-smoke wasm-tx-inspector;
            inherit tx-inspector-ui;
          };

          inherit checks apps;

          devShells = {
            default = project.shell;

            # Fast-iteration shell for the wasm-tx-inspector Haskell source.
            # Mounts the locked FOD deps cache + the wasm32-wasi toolchain, so
            # editing Inspector.hs + running `wasm32-wasi-cabal build` inside
            # docs/wasm/tx-inspector rebuilds in seconds (dist-newstyle stays
            # warm between invocations, no Nix sandbox re-entry).
            #
            # Usage:
            #   nix develop .#wasm-dev
            #   cd nix/wasm/tx-inspector
            #   export CABAL_DIR=$WASM_CABAL_DIR
            #   wasm32-wasi-cabal --project-file=cabal-wasm.project build wasm-tx-inspector
            wasm-dev = pkgs.mkShell {
              buildInputs = [
                ghc-wasm-meta.packages.${system}.all_9_12
                ghc-wasm-meta.packages.${system}.wasi-sdk
                pkgs.just
                pkgs.pkg-config
                pkgs.wasmtime
              ] ++ wasmTargets.wasm-tx-inspector.passthru.deps.nativeBuildInputs or [];

              shellHook = ''
                export WASM_CABAL_DIR="${wasmTargets.wasm-tx-inspector.passthru.deps}"
                echo "wasm-tx-inspector dev shell ready."
                echo "  WASM_CABAL_DIR=$WASM_CABAL_DIR   (locked FOD deps cache)"
                echo "  tools: wasm32-wasi-ghc, wasm32-wasi-cabal, wasi-sdk, wasmtime"
              '';
            };
          };
        };
    };
}
