#!/usr/bin/env bash
# Mechanical gate for cardano-node-clients#156 (factor
# withChainSyncFollower out of runDaemon). Every reviewed slice
# must pass this before the orchestrator accepts the commit.
#
# Will grow during plan/tasks to add the new follower spec.
# See gate-script skill ("Extended by the orchestrator").
set -euo pipefail

git diff --check
nix develop --quiet -c just build
nix develop --quiet -c just unit
nix develop --quiet -c cabal-fmt -c cardano-node-clients.cabal
nix develop --quiet -c sh -c "find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +"
nix develop --quiet -c sh -c "find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +"
