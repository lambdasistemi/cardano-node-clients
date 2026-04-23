# PureScript bundle for the WASM tx inspector demo.
#
# Gated behind its own flake inputs (purescript-overlay + mkSpagoDerivation) so
# downstream consumers who don't need the UI never instantiate the PS toolchain.
#
# Pattern ported from the /purescript skill (graph-browser, cardano-mpfs-browser):
#   1. importNpmLock.buildNodeModules → reproducible node_modules from committed
#      package-lock.json
#   2. esbuild bundles src/bootstrap.js (npm deps + WASM bytes as binary loader)
#      → dist/deps.js
#   3. spago bundle --offline --module Main → dist/index.js
#   4. Concatenate deps + app → final dist/index.js
#
# The inspector's .wasm is pulled in as a build-time input and copied into the
# src tree before bundling, so esbuild's `--loader:.wasm=binary` embeds it.
{ system
, nixpkgs
, purescript-overlay
, mkSpagoDerivation
, wasmArtifact        # derivation whose $out/<name>.wasm is the embedded binary
, wasmArtifactName    # e.g. "wasm-ledger-smoke"  (used to pick <name>.wasm)
, src                 # PS project tree (./docs/inspector relative to flake root)
}:

let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      purescript-overlay.overlays.default
      mkSpagoDerivation.overlays.default
    ];
  };

  nodeModules = pkgs.importNpmLock.buildNodeModules {
    npmRoot = src;
    nodejs = pkgs.nodejs_20;
  };

in
pkgs.mkSpagoDerivation {
  pname = "tx-inspector-ui";
  version = "0.1.0";
  inherit src;
  spagoYaml = src + "/spago.yaml";
  spagoLock = src + "/spago.lock";

  nativeBuildInputs = [
    pkgs.purs
    pkgs.spago-unstable
    pkgs.esbuild
    pkgs.nodejs_20
  ];

  buildPhase = ''
    ln -s ${nodeModules}/node_modules node_modules

    # Copy the WASM binary into the src tree so esbuild's --loader:.wasm=binary
    # can embed it at bundle time.
    mkdir -p src/assets
    cp ${wasmArtifact}/${wasmArtifactName}.wasm src/assets/inspector.wasm
    chmod -R u+w src/assets

    # 1. npm deps + WASM bytes → dist/deps.js (IIFE)
    esbuild src/bootstrap.js \
      --bundle \
      --outfile=dist/deps.js \
      --format=iife \
      --platform=browser \
      --loader:.wasm=binary \
      --minify

    # 2. PureScript → dist/index.js
    spago bundle --offline --module Main

    # 3. Concatenate deps first, then app
    cat dist/deps.js dist/index.js > dist/bundle.js
    mv dist/bundle.js dist/index.js
    rm dist/deps.js
  '';

  installPhase = ''
    mkdir -p $out
    cp dist/index.html $out/
    cp dist/index.js $out/
  '';

  passthru = { inherit nodeModules pkgs; };
}
