#!/usr/bin/env bash
set -euo pipefail

CLUSTER="us"
LOOP_FILE="/var/lib/rook-loopfile"
LOOP_SIZE="10G"

echo "Attaching loop devices to ${CLUSTER} worker nodes..."

WORKERS=$(docker ps --filter "name=${CLUSTER}-worker" --format '{{.Names}}')
for node in ${WORKERS}; do
    echo "  Setting up loop device on ${node}..."
    docker exec "${node}" truncate -s "${LOOP_SIZE}" "${LOOP_FILE}"
    docker exec "${node}" losetup -f "${LOOP_FILE}" 2>/dev/null || true
    echo "  ${node}: $(docker exec "${node}" losetup -a)"
done

echo "Loop devices attached."