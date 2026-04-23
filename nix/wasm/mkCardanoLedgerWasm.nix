# Turnkey WASM builder following haskell-mts's pattern (nix/wasm.nix).
#
# Two-phase FOD strategy:
#   1. Truncate Hackage at a pinned index-state + bootstrap cabal cache.
#   2. Mount CHaP (from the CHaP flake input) as a second local repo.
#   3. wasm32-wasi-cabal --only-download fetches tarballs (FOD, hash = dependenciesHash).
#   4. Offline wasm32-wasi-cabal build against the cached deps.
#
# Bypasses haskell.nix for the WASM compile; haskell.nix's cabalProject'
# is a native-GHC path, not a wasm32-wasi cross-compile.
{ pkgs
, lib
, ghcWasmMeta
, chap                  # Source tree of cardano-haskell-packages (flake input, flake = false)
}:

{ src                   # Source tree containing cabal-wasm.project + caller's cabal package
, packages              # [ "<exe-target>" ... ] — build targets for wasm32-wasi-cabal build
, dependenciesHash      # sha256 of the FOD dep-download phase; compute on first run
, srpForks ? []         # Subset of forks.pins names to pre-fetch and splice as `packages:` paths
, projectFile ? "cabal-wasm.project"
, extraCabalProject ? ""
, indexState ? null
, ghcVersion ? "9.12"
}:

let
  haskell-nix = pkgs.haskell-nix;
  forks = (import ./cabal-project-fragment.nix { inherit lib; }).forks;

  hackageIndexState = if indexState == null then forks.indexState.hackage else indexState;

  # --- Hackage -------------------------------------------------------------
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

  # --- CHaP ----------------------------------------------------------------
  # The CHaP flake input is a source tree containing 01-index.tar.gz at its root.
  # We use it as-is (no truncation); the cabal-wasm.project's index-state
  # clamp pins the effective resolution point.
  chapIndex = "${chap}/01-index.tar.gz";

  bootstrappedChap = pkgs.runCommand "cabal-bootstrap-cardano-haskell-packages" {
    nativeBuildInputs = [ haskell-nix.nix-tools.exes.cabal ]
      ++ haskell-nix.cabal-issue-8352-workaround;
  } ''
    HOME=$(mktemp -d)
    mkdir -p $HOME/.cabal/packages/cardano-haskell-packages
    cat <<EOF > $HOME/.cabal/config
    repository cardano-haskell-packages
      url: file:${
        haskell-nix.mkLocalHackageRepo {
          name = "cardano-haskell-packages";
          index = chapIndex;
        }
      }
      secure: True
      root-keys: aaa
      key-threshold: 0
    EOF
    cabal v2-update cardano-haskell-packages
    cp -r $HOME/.cabal/packages/cardano-haskell-packages $out
  '';

  # --- Merged CABAL_DIR ----------------------------------------------------
  dotCabal = pkgs.runCommand "dot-cabal-wasm" {
    nativeBuildInputs = [ pkgs.xorg.lndir ];
  } ''
    mkdir -p $out/packages/hackage.haskell.org
    lndir ${bootstrappedHackage} $out/packages/hackage.haskell.org

    mkdir -p $out/packages/cardano-haskell-packages
    lndir ${bootstrappedChap} $out/packages/cardano-haskell-packages

    cat > $out/config <<EOF
    repository hackage.haskell.org
      url: http://hackage.haskell.org/
      secure: True

    repository cardano-haskell-packages
      url: https://chap.intersectmbo.org/
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

  # Pre-fetch only the source-repository-package forks the caller asks for.
  # Adding every fork from forks.json globally would force unrelated packages
  # (plutus-core, etc.) into the solver as user goals.
  fetchFork = name:
    let pin = forks.pins.${name} or (throw "Unknown fork '${name}'; check nix/wasm/forks.json");
    in pkgs.fetchgit {
      url = pin.location;
      rev = pin.rev;
      hash = "sha256:${pin.sha256}";
    };

  prefetchedForks = lib.genAttrs srpForks fetchFork;

  forkPackageLines = lib.concatLists (
    map (name:
      let pin = forks.pins.${name};
      in if pin.subdirs == []
         then [ "  ${prefetchedForks.${name}}" ]
         else map (sub: "  ${prefetchedForks.${name}}/${sub}") pin.subdirs
    ) srpForks
  );

  forkPackagesBlock =
    if forkPackageLines == [] then ""
    else "packages:\n" + lib.concatStringsSep "\n" forkPackageLines + "\n";

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

      # Replace source-repository-package stanzas with direct package paths
      # pointing at pre-fetched nix store clones, so the offline build phase
      # does not need network to clone forks.
      sed -i '/^source-repository-package/,/^$/d' ${projectFile}
      cat >> ${projectFile} <<'EOF'
      ${forkPackagesBlock}
      EOF
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
