#!/usr/bin/env bash
# fetch-tx-cbor.sh — grab a Cardano tx's CBOR hex for the inspector demo.
#
# Usage:
#   fetch-tx-cbor.sh <tx-hash>           # mainnet, hex to stdout
#   fetch-tx-cbor.sh <tx-hash> preprod   # preprod testnet
#   fetch-tx-cbor.sh <tx-hash> | wl-copy       # pipe into clipboard (wayland)
#   fetch-tx-cbor.sh <tx-hash> | xclip -sel c  # pipe into clipboard (X11)
#   fetch-tx-cbor.sh <tx-hash> | pbcopy        # pipe into clipboard (macOS)
#
# If no arg: fetches the most recent tx of the most recent mainnet block.
# If $BLOCKFROST_PROJECT_ID is set, uses that; otherwise falls back to the
# demo keys in memory.

set -euo pipefail

NETWORK="${2:-mainnet}"

case "$NETWORK" in
    mainnet)
        BASE="https://cardano-mainnet.blockfrost.io/api/v0"
        PID="${BLOCKFROST_PROJECT_ID:-mainnetRuiuoEo0lhw6tJA3CGaVAoGM3kxIP11O}"
        ;;
    preprod)
        BASE="https://cardano-preprod.blockfrost.io/api/v0"
        PID="${BLOCKFROST_PROJECT_ID:-preprodwj5hJFlpil9JqOSszqDvfyKgYFfkcs0m}"
        ;;
    *)
        echo "unknown network: $NETWORK (expected mainnet or preprod)" >&2
        exit 2
        ;;
esac

HASH="${1:-}"
if [ -z "$HASH" ]; then
    HASH=$(curl -sS -H "project_id: $PID" "$BASE/blocks/latest/txs" | jq -r '.[0]')
    echo "no hash given; using latest: $HASH (network=$NETWORK)" >&2
fi

curl -sS -H "project_id: $PID" "$BASE/txs/$HASH/cbor" | jq -r .cbor
