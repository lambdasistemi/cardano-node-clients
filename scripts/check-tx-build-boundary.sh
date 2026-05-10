#!/usr/bin/env bash
set -euo pipefail

component="library tx-build"
cabal_file="cardano-node-clients.cabal"

forbidden=(
  "cardano-diffusion"
  "chain-follower"
  "contra-tracer"
  "network"
  "network-mux"
  "ouroboros-consensus"
  "ouroboros-network"
  "rocksdb"
  "typed-protocols"
)

stanza="$(
  awk '
    $0 == "library tx-build" { in_stanza = 1; print; next }
    in_stanza && $0 ~ /^[^[:space:]]/ { exit }
    in_stanza { print }
  ' "$cabal_file"
)"

if [[ -z "$stanza" ]]; then
  echo "tx-build boundary check failed: missing ${component}" >&2
  exit 1
fi

failed=0
for dep in "${forbidden[@]}"; do
  if grep -Eq "^[[:space:]]*,?[[:space:]]*${dep}([[:space:]:-]|$)" <<<"$stanza"; then
    echo "tx-build boundary check failed: forbidden dependency ${dep}" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "tx-build boundary check passed"
