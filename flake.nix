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
            #
            # Mounts prebuiltDeps (compiled full ledger closure, patched
            # project file with SRP forks inlined, precompiled dist-newstyle)
            # plus the wasm32-wasi toolchain. `wasm32-wasi-cabal build` uses
            # the precompiled libs — only Inspector.hs recompiles.
            #
            # First run populates a host-writable workspace under
            # $WASM_DEV_WORKSPACE; subsequent edits rebuild in seconds
            # because dist-newstyle stays warm between shell sessions.
            #
            # Usage:
            #   nix develop .#wasm-dev
            #   cd $WASM_DEV_WORKSPACE
            #   wasm32-wasi-cabal --project-file=cabal-wasm.project build wasm-tx-inspector
            wasm-dev =
              let
                preBuilt = wasmTargets.wasm-tx-inspector.passthru.prebuiltDeps;
                txInspectorSrc = ./nix/wasm/tx-inspector;
                cLibsLib = [
                  "${ghc-wasm-meta.packages.${system}.wasi-sdk}"
                ];
              in
              pkgs.mkShell {
                buildInputs = [
                  ghc-wasm-meta.packages.${system}.all_9_12
                  ghc-wasm-meta.packages.${system}.wasi-sdk
                  pkgs.just
                  pkgs.pkg-config
                  pkgs.wasmtime
                ];

                shellHook = ''
                  export WASM_PREBUILT_DEPS="${preBuilt}"
                  export WASM_DEV_WORKSPACE="$PWD/.wasm-dev-workspace"

                  if [ ! -d "$WASM_DEV_WORKSPACE" ]; then
                    echo "wasm-dev: materializing workspace from prebuiltDeps (first run)..."
                    mkdir -p "$WASM_DEV_WORKSPACE"
                    cp -rL ${txInspectorSrc}/* "$WASM_DEV_WORKSPACE/"
                    chmod -R u+w "$WASM_DEV_WORKSPACE"
                    # Replace the SRP-laden project file with the pre-patched
                    # one from prebuiltDeps (SRP stanzas already rewritten to
                    # nix-store `packages:` paths).
                    cp -L "$WASM_PREBUILT_DEPS/cabal-wasm.project" \
                          "$WASM_DEV_WORKSPACE/cabal-wasm.project"
                    # Seed dist-newstyle with the pre-compiled library graph.
                    cp -rL "$WASM_PREBUILT_DEPS/dist-newstyle" \
                           "$WASM_DEV_WORKSPACE/dist-newstyle"
                    chmod -R u+w "$WASM_DEV_WORKSPACE"
                    echo "wasm-dev: workspace ready at $WASM_DEV_WORKSPACE"
                  fi

                  export CABAL_DIR="$WASM_DEV_WORKSPACE/.cabal"
                  if [ ! -d "$CABAL_DIR" ]; then
                    cp -rL "$WASM_PREBUILT_DEPS/cabal" "$CABAL_DIR"
                    chmod -R u+w "$CABAL_DIR"
                  fi

                  echo "wasm-tx-inspector dev shell ready."
                  echo "  WASM_DEV_WORKSPACE=$WASM_DEV_WORKSPACE  (edit here; dist-newstyle stays warm)"
                  echo "  CABAL_DIR=$CABAL_DIR                   (compiled deps cache)"
                  echo "  cd \$WASM_DEV_WORKSPACE && wasm32-wasi-cabal --project-file=cabal-wasm.project build wasm-tx-inspector"
                '';
              };
          };
        };
    };
}
