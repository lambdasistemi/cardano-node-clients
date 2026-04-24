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
, wasiSdk ? null        # ghc-wasm-meta.packages.<sys>.wasi-sdk; only required when cLibs != null
, chap                  # Source tree of cardano-haskell-packages (flake input, flake = false)
}:

{ src                   # Source tree containing cabal-wasm.project + caller's cabal package
, packages              # [ "<exe-target>" ... ] — build targets for wasm32-wasi-cabal build
, dependenciesHash      # sha256 of the FOD dep-download phase; compute on first run
, srpForks ? []         # Subset of forks.pins names to pre-fetch and splice as `packages:` paths
, withCLibs ? false     # Build and wire wasm32-wasi-built libsodium + secp256k1 + blst
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
  # The CHaP flake input is a complete hackage-repository tree (01-index.tar.gz
  # plus root.json / snapshot.json / timestamp.json / mirrors.json), so we
  # point cabal at it directly — no mkLocalHackageRepo (which re-signs with
  # fake keys that clash with the real root keys the index references).

  bootstrappedChap = pkgs.runCommand "cabal-bootstrap-cardano-haskell-packages" {
    nativeBuildInputs = [ haskell-nix.nix-tools.exes.cabal ]
      ++ haskell-nix.cabal-issue-8352-workaround;
  } ''
    HOME=$(mktemp -d)
    mkdir -p $HOME/.cabal/packages/cardano-haskell-packages
    cat <<EOF > $HOME/.cabal/config
    repository cardano-haskell-packages
      url: file:${chap}
      secure: True
      root-keys:
        3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
        443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
        a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
        bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
        c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
        d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee
      key-threshold: 3
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
      root-keys:
        3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
        443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
        a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
        bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
        c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
        d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee
      key-threshold: 3

    executable-stripping: False
    shared: True
    EOF
  '';

  # Metadata-only filter: .cabal files + the wasm project file.
  # Deliberately excludes .hs sources so the derivation hash of anything
  # consuming `srcMetadata` is stable across Haskell edits.
  #
  # CRITICAL: set `name` to match the underlying src's final path component
  # so the extracted sandbox path (`/build/<name>`) is identical between
  # prebuiltDeps and wasm. Cabal bakes absolute paths into dist-newstyle
  # metadata and compiled artifacts; mismatched sandbox paths cause cabal
  # to treat the cached compile as stale and rebuild the whole closure.
  #
  # `cleanSourceWith` defaults `name` to "source" when not set, regardless
  # of the underlying src's directory name — that's what broke the cache in
  # the first attempt.
  srcMetadata = lib.cleanSourceWith {
    name = builtins.baseNameOf (toString src);
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

  cLibs =
    if withCLibs
    then
      assert lib.assertMsg (wasiSdk != null) ''
        mkCardanoLedgerWasm: withCLibs = true requires wasiSdk (use
        ghc-wasm-meta.packages.<sys>.wasi-sdk).
      '';
      import ./c-libs {
        inherit pkgs;
        wasi-sdk = wasiSdk;
      }
    else null;

  cLibsInputs = if cLibs == null then [] else cLibs.all ++ [ pkgs.pkg-config ];
  cLibsPkgConfigPath = if cLibs == null then "" else cLibs.pkgConfigPath;

  # cabal's --extra-lib-dirs / --extra-include-dirs so cardano-crypto-class's
  # configure step finds blst/secp256k1/libsodium via the linker and headers.
  cLibsExtraLibDirs =
    if cLibs == null then []
    else [
      "${cLibs.libsodium}/lib"
      "${cLibs.secp256k1}/lib"
      "${cLibs.blst}/lib"
    ];
  cLibsExtraIncludeDirs =
    if cLibs == null then []
    else [
      "${cLibs.libsodium}/include"
      "${cLibs.secp256k1.dev}/include"
      "${cLibs.blst}/include"
    ];
  cabalExtraDirsArgs = lib.concatStringsSep " " (
    (map (d: "--extra-lib-dirs=${d}") cLibsExtraLibDirs) ++
    (map (d: "--extra-include-dirs=${d}") cLibsExtraIncludeDirs)
  );

  deps = pkgs.stdenv.mkDerivation {
    pname = "cardano-ledger-wasm-deps";
    version = "0.1.0";
    src = srcMetadata;

    nativeBuildInputs = [ ghcWasmMeta pkgs.cacert pkgs.git pkgs.curl ]
      ++ cLibsInputs;

    buildPhase = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p $HOME
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export CURL_CA_BUNDLE=$SSL_CERT_FILE
      ${lib.optionalString (cLibs != null) "export PKG_CONFIG_PATH=${cLibsPkgConfigPath}"}

      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      mkdir -p $CABAL_DIR
      cp -rL ${dotCabal}/* $CABAL_DIR/
      chmod -R u+w $CABAL_DIR

      wasm32-wasi-cabal --project-file=${projectFile} build \
        --only-download \
        ${cabalExtraDirsArgs} \
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

  # prebuiltDeps: compile the full ledger-closure library graph once.
  #
  # Input: srcMetadata (cabal files + project file only — NO .hs files) + the
  # FOD deps tarball cache. Output: $out = a full $CABAL_DIR plus dist-newstyle
  # tree with every dependency library already compiled for wasm32-wasi, plus
  # the patched project file with SRP stanzas rewritten to local `packages:`.
  #
  # Because src is metadata-only, this derivation's hash is stable across
  # Haskell source edits — rebuilds only when cabal files / project file /
  # forks.json / ghc-wasm-meta / c-libs change.
  #
  # This is a regular (non-FOD) derivation: the compile output is not
  # reproducible byte-for-byte across machines (GHC WASM is non-deterministic),
  # but Nix's regular content-addressing caches it per-machine and per-team
  # Cachix — good enough for incremental iteration. Only the exe compile +
  # link in the downstream `wasm` derivation re-runs on Haskell source edits.
  prebuiltDeps = pkgs.stdenv.mkDerivation {
    pname = "cardano-ledger-wasm-prebuilt-deps";
    version = "0.1.0";
    src = srcMetadata;

    nativeBuildInputs = [ ghcWasmMeta pkgs.git ] ++ cLibsInputs;

    configurePhase = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p $HOME
      ${lib.optionalString (cLibs != null) "export PKG_CONFIG_PATH=${cLibsPkgConfigPath}"}

      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      mkdir -p $CABAL_DIR
      cp -rL ${deps}/* $CABAL_DIR/
      chmod -R u+w $CABAL_DIR

      # Rewrite source-repository-package stanzas to packages: <store-path>
      # once, here, so both prebuiltDeps (this derivation) and the downstream
      # wasm derivation share the same patched project file.
      sed -i '/^source-repository-package/,/^$/d' ${projectFile}
      cat >> ${projectFile} <<'EOF'
      ${forkPackagesBlock}
      EOF
    '';

    buildPhase = ''
      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      ${lib.optionalString (cLibs != null) "export PKG_CONFIG_PATH=${cLibsPkgConfigPath}"}
      wasm32-wasi-cabal --project-file=${projectFile} build \
        --only-dependencies \
        ${cabalExtraDirsArgs} \
        ${buildTargetsArg}
    '';

    installPhase = ''
      mkdir -p $out
      cp -rL $CABAL_DIR $out/cabal
      cp -rL dist-newstyle $out/dist-newstyle
      # Preserve the patched project file so the wasm phase can reuse it.
      cp ${projectFile} $out/${projectFile}
      chmod -R u+w $out
    '';
  };

  # wasm: compile the inspector exe against prebuiltDeps' compiled closure.
  #
  # Input: the FULL source tree (including .hs) + prebuiltDeps output.
  # Haskell source edits rehash THIS derivation only; prebuiltDeps is reused
  # from the cache, so the ledger closure does not recompile. Expected rebuild
  # time on Inspector.hs edits: 1-3 minutes (inspector lib + exe + link).
  wasm = pkgs.stdenv.mkDerivation {
    pname = "cardano-ledger-wasm";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [ ghcWasmMeta pkgs.git ] ++ cLibsInputs;

    configurePhase = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p $HOME
      ${lib.optionalString (cLibs != null) "export PKG_CONFIG_PATH=${cLibsPkgConfigPath}"}

      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      mkdir -p $CABAL_DIR
      cp -rL ${prebuiltDeps}/cabal/* $CABAL_DIR/
      chmod -R u+w $CABAL_DIR

      # Reuse the compiled dist-newstyle from prebuiltDeps; cabal sees the
      # library deps as already up-to-date and skips their rebuild.
      cp -rL ${prebuiltDeps}/dist-newstyle dist-newstyle
      chmod -R u+w dist-newstyle

      # Drop the consumer's source project file; use the patched one from
      # prebuiltDeps so SRP stanzas are already rewritten to packages: paths.
      rm -f ${projectFile}
      cp ${prebuiltDeps}/${projectFile} ${projectFile}
      chmod u+w ${projectFile}
    '';

    buildPhase = ''
      export CABAL_DIR=$NIX_BUILD_TOP/cabal
      ${lib.optionalString (cLibs != null) "export PKG_CONFIG_PATH=${cLibsPkgConfigPath}"}
      wasm32-wasi-cabal --project-file=${projectFile} build \
        ${cabalExtraDirsArgs} \
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
      inherit deps prebuiltDeps;
      forks = forks;
    };
  };
in
wasm
