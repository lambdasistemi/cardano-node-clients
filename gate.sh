#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix develop --quiet -c just ci
timeout 10m nix build --quiet \
  .#checks.x86_64-linux.build \
  .#checks.x86_64-linux.unit \
  .#checks.x86_64-linux.e2e \
  .#checks.x86_64-linux.lint
