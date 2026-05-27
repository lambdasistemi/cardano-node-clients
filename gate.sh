#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c cabal build all -O0
nix develop --quiet -c just unit
nix develop --quiet -c just e2e
nix develop --quiet -c cabal-fmt -c cardano-node-clients.cabal
nix develop --quiet -c find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check '{}' +
nix develop --quiet -c just hlint
