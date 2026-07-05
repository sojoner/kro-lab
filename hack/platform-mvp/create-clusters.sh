#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HUB_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-hub.yaml"
US_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-us.yaml"

echo "Creating hub cluster..."
kind create cluster --name hub --config "${HUB_CONFIG}"

echo "Creating us cluster..."
kind create cluster --name us --config "${US_CONFIG}"

echo "Verifying clusters..."
kubectl --context kind-hub get nodes
kubectl --context kind-us get nodes

echo "Extracting us cluster internal kubeconfig..."
kind get kubeconfig --name us --internal > "${ROOT_DIR}/hack/platform-mvp/kubeconfig-us-internal"

echo "Testing cross-cluster reachability..."
HUB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-hub-control-plane)
docker exec kind-us-control-plane ping -c1 "${HUB_IP}"

echo "Clusters ready."
echo "  hub context: kind-hub"
echo "  us context: kind-us"
echo "  us internal kubeconfig: hack/platform-mvp/kubeconfig-us-internal"