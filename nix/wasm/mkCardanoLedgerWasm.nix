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
, chap
}:

{ src
, packages
, extraCabalProject ? ""
, indexState ? null
, ghcVersion ? "9.10"
}:

assert lib.assertMsg (ghcVersion == "9.10") ''
  mkCardanoLedgerWasm currently supports only GHC 9.10.
  IntersectMBO/cardano-api master's wasmShell uses all_9_10; GHC 9.12 clashes
  with the basement/foundation fork on word64ToWord#. This will relax once the
  upstream forks catch up to 9.12.
'';

let
  project = import ./project.nix {
    inherit pkgs lib ghcWasmMeta chap src extraCabalProject;
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
