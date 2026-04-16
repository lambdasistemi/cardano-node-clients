#!/bin/bash
set -eu

# Devnet entrypoint: patches genesis timestamps and starts cardano-node.
#
# Environment variables:
#   START_OFFSET  - seconds into the future for systemStart (default: 5)
#   GENESIS_DIR   - source genesis directory (default: /genesis)
#   DATA_DIR      - node data directory (default: /data)

START_OFFSET="${START_OFFSET:-5}"
GENESIS_DIR="${GENESIS_DIR:-/genesis}"
DATA_DIR="${DATA_DIR:-/data}"

WORK_DIR="${DATA_DIR}/genesis"
KEYS_DIR="${WORK_DIR}/delegate-keys"

mkdir -p "${WORK_DIR}" "${KEYS_DIR}" "${DATA_DIR}/db"

# Copy genesis files to writable location
for f in alonzo-genesis.json conway-genesis.json dijkstra-genesis.json node-config.json topology.json; do
    cp "${GENESIS_DIR}/${f}" "${WORK_DIR}/${f}"
done

# Copy delegate keys with correct permissions
for f in delegate1.kes.skey delegate1.vrf.skey delegate1.opcert; do
    cp "${GENESIS_DIR}/delegate-keys/${f}" "${KEYS_DIR}/${f}"
    chmod 400 "${KEYS_DIR}/${f}"
done

# Compute start time: now + offset
start_epoch=$(($(date +%s) + START_OFFSET))
start_utc=$(date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "${start_epoch}" +%Y-%m-%dT%H:%M:%SZ)

echo "Devnet systemStart: ${start_utc} (offset: ${START_OFFSET}s)"

# Patch shelley-genesis.json: replace PLACEHOLDER with start time
shelley=$(cat "${GENESIS_DIR}/shelley-genesis.json")
echo "${shelley//PLACEHOLDER/$start_utc}" > "${WORK_DIR}/shelley-genesis.json"

# Patch byron-genesis.json: replace "startTime": 0 with current epoch
byron=$(cat "${GENESIS_DIR}/byron-genesis.json")
echo "${byron//\"startTime\": 0/\"startTime\": $start_epoch}" > "${WORK_DIR}/byron-genesis.json"

exec cardano-node run \
    --config "${WORK_DIR}/node-config.json" \
    --topology "${WORK_DIR}/topology.json" \
    --database-path "${DATA_DIR}/db" \
    --socket-path "${DATA_DIR}/node.sock" \
    --shelley-kes-key "${KEYS_DIR}/delegate1.kes.skey" \
    --shelley-vrf-key "${KEYS_DIR}/delegate1.vrf.skey" \
    --shelley-operational-certificate "${KEYS_DIR}/delegate1.opcert" \
    --port 3001
