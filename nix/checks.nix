{ pkgs, src, components, cardanoNode, lintPkgs ? pkgs }:
let
  lib = pkgs.lib;

  mkCheck = name: script:
    pkgs.runCommand "${name}-check" {
      nativeBuildInputs =
        lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.glibcLocales ];
      LANG = "C.UTF-8";
      LC_ALL = "C.UTF-8";
    } ''
      set -euo pipefail
      cd ${src}
      ${lib.getExe script}
      touch "$out"
    '';

  mkScript = { name, runtimeInputs ? [ ], text }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs text;
    };

  mkGate = spec:
    let
      script = mkScript spec;
    in
    {
      check = mkCheck spec.name script;
      inherit script;
    };

  lintInputs = [
    lintPkgs.haskellPackages.cabal-fmt
    lintPkgs.haskellPackages.fourmolu
    lintPkgs.haskellPackages.hlint
    pkgs.bash
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
  ];

  gateSpecs = {
    build = {
      name = "build";
      text = ''
        test -e ${components.library}
        test -e ${components.sublibs."utxo-indexer-lib"}
        test -e ${components.exes.cardano-adversary}
        test -e ${components.exes.utxo-indexer}
        echo "build outputs realized"
      '';
    };

    e2e = {
      name = "e2e";
      runtimeInputs = [
        cardanoNode
        components.tests.e2e-tests
      ];
      text = ''
        e2e-tests
      '';
    };

    unit = {
      name = "unit";
      runtimeInputs = [
        components.tests.unit-tests
      ];
      text = ''
        unit-tests
      '';
    };

    lint = {
      name = "lint";
      runtimeInputs = lintInputs;
      text = ''
        cd ${src}
        cabal-fmt -c cardano-node-clients.cabal
        find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +
        find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +
      '';
    };
  };

  gates = lib.mapAttrs (_: mkGate) gateSpecs;
in
{
  checks = lib.mapAttrs (_: gate: gate.check) gates;
  scripts = lib.mapAttrs (_: gate: gate.script) gates;
}
