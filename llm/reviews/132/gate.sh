#!/usr/bin/env bash
# Quality gate for PR #132 (issue #130).
#
# Inner-loop slice gate for PR #132. Finalization still runs the full
# constitution gate (`nix develop --quiet -c just ci`); this script keeps
# ordinary slice handoffs focused, then optionally runs the Conway boundary
# smoke against a real node with GATE_FULL=1.
#
# Run from the worktree root inside `nix develop` (or via `nix develop -c
# ./llm/reviews/132/gate.sh`).
set -euo pipefail

echo "== build =="
cabal build all -O0

echo "== unit + tx-build tests =="
cabal test cardano-node-clients:unit-tests -O0 --test-show-details=direct
cabal test cardano-node-clients:tx-build-tests -O0 --test-show-details=direct

echo "== fourmolu (check) =="
find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +

echo "== hlint =="
find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +

echo "== cabal-fmt (check) =="
cabal-fmt -c cardano-node-clients.cabal

# Boundary smoke: only run when GATE_FULL=1 (devnet boot is slow).
# The reviewer must require GATE_FULL=1 on the final approval round.
if [[ "${GATE_FULL:-0}" == "1" ]]; then
    echo "== e2e (devnet, includes Conway cert + treasury proposal smoke) =="
    cabal test cardano-node-clients:e2e-tests -O0 --test-show-details=direct \
        --test-option=--match \
        --test-option='/Cardano.Node.Client.E2E.TxBuildConwaySpec/'
fi
