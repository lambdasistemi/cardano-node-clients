{ pkgs, src, components, cardanoNode, lintPkgs ? pkgs }:
let
  build = pkgs.writeShellApplication {
    name = "build";
    text = ''
      test -e ${components.library}
      test -e ${components.sublibs.devnet}
      echo "build outputs realized"
    '';
  };

  e2e = pkgs.writeShellApplication {
    name = "e2e";
    runtimeInputs = [
      cardanoNode
      components.tests.e2e-tests
    ];
    text = ''
      exec e2e-tests
    '';
  };

  unit = pkgs.writeShellApplication {
    name = "unit";
    runtimeInputs = [
      components.tests.unit-tests
    ];
    text = ''
      exec unit-tests
    '';
  };

  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = with lintPkgs.haskellPackages; [
      cabal-fmt
      fourmolu
      hlint
    ];
    text = ''
      cd ${src}
      cabal-fmt -c cardano-node-clients.cabal
      find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +
      find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +
    '';
  };
in
{
  inherit build e2e lint unit;
}
