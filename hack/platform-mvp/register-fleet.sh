#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CLUSTER_PROFILE="${ROOT_DIR}/deploy/platform-mvp/fleet/clusterprofile-us.yaml"
KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig-us-internal"

if [ ! -f "${KUBECONFIG_FILE}" ]; then
    echo "Extracting us cluster internal kubeconfig..."
    kind get kubeconfig --name us --internal > "${KUBECONFIG_FILE}"
fi

echo "Creating kubeconfig secret on hub..."
kubectl --context kind-hub create secret generic us-kubeconfig \
    --from-file=value="${KUBECONFIG_FILE}" \
    --dry-run=client -o yaml | kubectl --context kind-hub apply -f -

echo "Applying ClusterProfile on hub..."
kubectl --context kind-hub apply -f "${CLUSTER_PROFILE}"

echo "Verifying fleet registration..."
kubectl --context kind-hub get clusterprofile us -o yaml

echo "Fleet registration complete."