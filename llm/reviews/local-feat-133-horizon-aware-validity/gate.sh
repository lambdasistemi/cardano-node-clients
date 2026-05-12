#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nix develop --quiet -c just ci
