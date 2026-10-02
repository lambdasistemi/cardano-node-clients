{ pkgs, src, components, cardanoNode, faultRunner, lintPkgs ? pkgs }:
let
  lib = pkgs.lib;

  # The production source with one fault patch applied. A patch that
  # does not apply exactly leaves the source unpatched and records
  # `fault-not-applied`, so the check reports a setup failure instead
  # of judging the guard against production code.
  faultSource = name: patch:
    pkgs.runCommand "${name}-source" {
      nativeBuildInputs = [ pkgs.patch ];
    } ''
      cp -r ${src} "$out"
      chmod -R u+w "$out"
      if patch -d "$out" -p1 --forward --batch --fuzz=0 \
          --no-backup-if-mismatch < ${patch}; then
        echo applied > "$out/.fault-status"
      else
        rm -rf "$out"
        cp -r ${src} "$out"
        chmod -R u+w "$out"
        echo fault-not-applied > "$out/.fault-status"
      fi
    '';

  # The fault-check script. Exit codes: 0 KILLED, 3 SURVIVED,
  # 2 SETUP-FAILURE:<reason> (any failure inside this script
  # included); it never exits 1 itself. A faulted tree that does not
  # build fails in nix before the script runs: exit 1 and no
  # FAULT-CHECK line, which is the build-failed setup failure.
  faultCheckText = { name, example, statusFile }: ''
    example=${lib.escapeShellArg example}
    report() {
      echo "FAULT-CHECK ${name} outcome=$1 example=$example"
    }
    trap 'report "SETUP-FAILURE:harness-failed"; exit 2' ERR
    status=$(cat ${statusFile})
    if [ "$status" != applied ]; then
      report "SETUP-FAILURE:$status"
      exit 2
    fi
    code=0
    output=$(fault-check "$example") || code=$?
    outcome=''${output##*$'\n'}
    case "$code:$outcome" in
      0:KILLED) report KILLED; exit 0 ;;
      3:SURVIVED) report SURVIVED; exit 3 ;;
      2:SETUP-FAILURE:*) report "$outcome"; exit 2 ;;
      *) report "SETUP-FAILURE:harness-failed"; exit 2 ;;
    esac
  '';

  # A fault check: build the fault-check runner from the patched
  # source and run the one guarding example through the script above.
  mkFaultSpec = { name, patch, example }:
    let
      faultSrc = faultSource name patch;
    in
    {
      inherit name;
      runtimeInputs = [ (faultRunner faultSrc) pkgs.coreutils ];
      text = faultCheckText {
        inherit name example;
        statusFile = "${faultSrc}/.fault-status";
      };
    };

  # The same script against a stub runner whose output and exit code
  # each case sets, so every outcome path is driven and its exit code
  # and outcome line asserted.
  faultCheckUnderTest = mkScript {
    name = "fault-check-under-test";
    runtimeInputs = [ faultCheckStub pkgs.coreutils ];
    text = faultCheckText {
      name = "fault-under-test";
      example = "group/example";
      statusFile = ''"$FAULT_STATUS_FILE"'';
    };
  };

  faultCheckStub = mkScript {
    name = "fault-check";
    text = ''
      printf '%b' "$STUB_OUTPUT"
      exit "$STUB_EXIT"
    '';
  };

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

    fault-check-runner = {
      name = "fault-check-runner";
      runtimeInputs = [ faultCheckUnderTest pkgs.coreutils ];
      text = ''
        failures=0
        cases=0
        # expect <fault status|missing> <runner output> <runner exit>
        #        <expected outcome> <expected exit>
        expect() {
          local dir got code line
          cases=$((cases + 1))
          dir=$(mktemp -d)
          if [ "$1" != missing ]; then
            echo "$1" > "$dir/status"
          fi
          code=0
          got=$(FAULT_STATUS_FILE="$dir/status" STUB_OUTPUT="$2" \
            STUB_EXIT="$3" fault-check-under-test 2>/dev/null) || code=$?
          rm -rf "$dir"
          line="FAULT-CHECK fault-under-test outcome=$4 example=group/example"
          if [ "$code" = "$5" ] && [ "$code" != 1 ] && [ "$got" = "$line" ]; then
            echo "ok   outcome=$4 exit=$code (status $1, runner '$2' exit $3)"
          else
            echo "FAIL want '$line' exit $5, got '$got' exit $code (status $1, runner '$2' exit $3)"
            failures=$((failures + 1))
          fi
        }
        expect applied 'KILLED' 0 KILLED 0
        expect applied 'detail\nKILLED' 0 KILLED 0
        expect applied 'SURVIVED' 3 SURVIVED 3
        for reason in usage example-not-run example-not-unique \
            example-pending failed-by-exception; do
          expect applied "SETUP-FAILURE:$reason" 2 "SETUP-FAILURE:$reason" 2
        done
        expect fault-not-applied 'KILLED' 0 SETUP-FAILURE:fault-not-applied 2
        expect missing 'KILLED' 0 SETUP-FAILURE:harness-failed 2
        expect applied 'KILLED' 1 SETUP-FAILURE:harness-failed 2
        expect applied 'SURVIVED' 1 SETUP-FAILURE:harness-failed 2
        expect applied 'KILLED' 3 SETUP-FAILURE:harness-failed 2
        expect applied ''' 139 SETUP-FAILURE:harness-failed 2
        expect applied 'garbage' 0 SETUP-FAILURE:harness-failed 2
        echo "fault-check runner: $cases cases, $failures failures"
        [ "$failures" = 0 ]
      '';
    };

    fault-asset-matching = mkFaultSpec {
      name = "fault-asset-matching";
      patch = ./faults/asset-matching.patch;
      example = "Cardano.Node.Client.UTxOIndexer asset index/transactional maintenance against the model (I1)/matches after create, move, split, partial spend and burn";
    };

    fault-snapshot-binding = mkFaultSpec {
      name = "fault-snapshot-binding";
      patch = ./faults/snapshot-binding.patch;
      example = "Cardano.Node.Client.UTxOIndexer asset index/concurrent snapshots (I5)/every snapshot equals the model state at its point";
    };

    fault-view-snapshot-binding = mkFaultSpec {
      name = "fault-view-snapshot-binding";
      patch = ./faults/view-snapshot-binding.patch;
      example = "Cardano.Node.Client.UTxOIndexer indexed view/every concurrent view equals the model state at its point on both backends";
    };

    fault-socket-view-snapshot-binding = mkFaultSpec {
      name = "fault-socket-view-snapshot-binding";
      patch = ./faults/socket-view-snapshot-binding.patch;
      example = "utxo-indexer socket read view/every answer equals independent state at the reported point across a controlled advance";
    };
  };

  gates = lib.mapAttrs (_: mkGate) gateSpecs;
in
{
  checks = lib.mapAttrs (_: gate: gate.check) gates;
  scripts = lib.mapAttrs (_: gate: gate.script) gates;
}
