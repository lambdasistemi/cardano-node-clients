# Public entry point for downstream consumers.
#
# Contract: see ../../specs/033-wasm-ledger-inspector/contracts/nix-api.md
#
# Turnkey builder: given a caller-chosen set of ledger packages and a source
# tree containing the consumer's cabal package, returns a derivation that
# produces a wasm32-wasi artifact.
{ pkgs
, lib
, ghcWasmMeta
}:

{ src
, packages
, extraCabalProject ? ""
, indexState ? null
, ghcVersion ? "9.12"
}:

assert lib.assertMsg (ghcVersion == "9.12") ''
  mkCardanoLedgerWasm currently supports only GHC 9.12.
  Template Haskell on the WASM backend requires 9.12.1+ (see research.md Decision 1).
'';

let
  project = import ./project.nix {
    inherit pkgs lib ghcWasmMeta src extraCabalProject;
  };

  # For each requested package, pick its library component.
  selectedLibs = lib.listToAttrs (
    map (pkgName: {
      name = pkgName;
      value = project.hsPkgs.${pkgName}.components.library;
    }) packages
  );
in
pkgs.symlinkJoin {
  name = "cardano-ledger-wasm-bundle";
  paths = lib.attrValues selectedLibs;
  postBuild = ''
    # Expose the selected package list as metadata.
    mkdir -p $out/share
    cat > $out/share/manifest.json <<EOF
    {
      "packages": [${lib.concatMapStringsSep ", " (p: "\"${p}\"") packages}],
      "ghcVersion": "${ghcVersion}"
    }
    EOF
  '';

  passthru = {
    inherit project;
    inherit selectedLibs;
    forks = (import ./cabal-project-fragment.nix { inherit lib; }).forks;
  };
}
