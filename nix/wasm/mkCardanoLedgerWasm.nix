# Turnkey WASM builder following haskell-mts's pattern (nix/wasm.nix).
#
# Two-phase FOD strategy:
#   1. Truncate Hackage at a pinned index-state + bootstrap cabal cache.
#   2. wasm32-wasi-cabal --only-download fetches tarballs (FOD, hash = dependenciesHash).
#   3. Offline wasm32-wasi-cabal build against the cached deps.
#
# This bypasses haskell.nix for the WASM compile — haskell.nix's cabalProject'
# is native-GHC, not a wasm32-wasi cross-compile. The pattern matches what
# IntersectMBO/cardano-api does in CI and what paolino/cardano-addresses
# branch 001-wasm-target does.
{ pkgs
, lib
, ghcWasmMeta
, chap                  # kept for signature compatibility; currently unused here
}:

{ src                   # Source tree containing cabal-wasm.project + package
, packages              # [ "<exe-target>" ... ] — targets passed to wasm32-wasi-cabal build
, dependenciesHash      # sha256 of the FOD dep-download phase; compute on first run
, projectFile ? "cabal-wasm.project"
, extraCabalProject ? ""
, indexState ? null
, ghcVersion ? "9.12"
}:

let
  haskell-nix = pkgs.haskell-nix;
  forks = (import ./cabal-project-fragment.nix { inherit lib; }).forks;

  hackageIndexState = if indexState == null then forks.indexState.hackage else indexState;

  truncatedHackageIndex = pkgs.fetchurl {
    name = "01-index.tar.gz-at-${hackageIndexState}";
    url = "https://hackage.haskell.org/01-index.tar.gz";
    downloadToTemp = true;
    postFetch = ''
      ${haskell-nix.nix-tools}/bin/truncate-index \
        -o $out -i $downloadedFile -s '${hackageIndexState}'
    '';
    outputHashAlgo = "sha256";
    outputHash = (import haskell-nix.indexStateHashesPath).${hackageIndexState};
  };

  bootstrappedHackage = pkgs.runCommand "cabal-bootstrap-hackage.haskell.org" {
    nativeBuildInputs = [ haskell-nix.nix-tools.exes.cabal ]
      ++ haskell-nix.cabal-issue-8352-workaround;
  } ''
    HOME=$(mktemp -d)
    mkdir -p $HOME/.cabal/packages/hackage.haskell.org
    cat <<EOF > $HOME/.cabal/config
    repository hackage.haskell.org
      url: file:${
        haskell-nix.mkLocalHackageRepo {
          name = "hackage.haskell.org";
          index = truncatedHackageIndex;
        }
      }
      secure: True
      root-keys: aaa
      key-threshold: 0
    EOF
    cabal v2-update hackage.haskell.org
    cp -r $HOME/.cabal/packages/hackage.haskell.org $out
  '';

  dotCabal = pkgs.runCommand "dot-cabal-wasm" {
    nativeBuildInputs = [ pkgs.xorg.lndir ];
  } ''
    mkdir -p $out/packages/hackage.haskell.org
    lndir ${bootstrappedHackage} $out/packages/hackage.haskell.org

    cat > $out/config <<EOF
    repository hackage.haskell.org
      url: http://hackage.haskell.org/
      secure: True

    executable-stripping: False
    shared: True
    EOF
  '';

  srcMetadata = lib.cleanSourceWith {
    inherit src;
    filter = name: type:
      let baseName = baseNameOf (toString name);
      in type == "directory"
         || lib.hasSuffix ".cabal" baseName
         || baseName == projectFile
         || baseName == "cabal.project";
  };

  buildTargetsArg = lib.concatStringsSep " \\\n      " packages;

  deps = pkgs.stdenv.mkDerivation {
    pname = "cardano-ledger-wasm-deps";
    version = "0.1.0";
    src = srcMetadata;

    nativeBuildInputs = [ ghcWasmMeta pkgs.cacert pkgs.git pkgs.curl ];

    buildPhase = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p $HOME
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export CURL_CA_BUNDLE=$SSL_CERT_FILE

      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      mkdir -p $CABAL_DIR
      cp -rL ${dotCabal}/* $CABAL_DIR/
      chmod -R u+w $CABAL_DIR

      wasm32-wasi-cabal --project-file=${projectFile} build \
        --only-download \
          ${buildTargetsArg}
    '';

    installPhase = ''
      mkdir -p $out
      cp -r $CABAL_DIR/* $out/
      find $out -name 'hackage-security-lock' -delete
      find $out -name '01-index.timestamp' -delete
    '';

    outputHashMode = "recursive";
    outputHash = dependenciesHash;
  };

  wasm = pkgs.stdenv.mkDerivation {
    pname = "cardano-ledger-wasm";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [ ghcWasmMeta pkgs.git ];

    configurePhase = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p $HOME

      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      mkdir -p $CABAL_DIR
      cp -rL ${deps}/* $CABAL_DIR/
      chmod -R u+w $CABAL_DIR
    '';

    buildPhase = ''
      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      wasm32-wasi-cabal --project-file=${projectFile} build \
        ${buildTargetsArg}
    '';

    installPhase = ''
      mkdir -p $out
      for target in ${buildTargetsArg}; do
        find dist-newstyle -name "$target.wasm" -type f \
          -exec cp {} $out/$target.wasm \; || true
      done
    '';

    passthru = {
      inherit deps;
      forks = forks;
    };
  };
in
wasm
