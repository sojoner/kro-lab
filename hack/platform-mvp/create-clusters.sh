#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HUB_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-hub.yaml"
US_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-us.yaml"
US_AUTH_DIR="/tmp/kro-us-auth"

echo "Creating hub cluster..."
kind create cluster --name hub --config "${HUB_CONFIG}"

HUB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hub-control-plane)

echo "Preparing us AuthenticationConfiguration..."
mkdir -p "${US_AUTH_DIR}"
cat > "${US_AUTH_DIR}/authentication-configuration.yaml" << AUTHCONFIG
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://bm4080.taildf7067.ts.net/dex
      audiences:
        - kubernetes
    claimMappings:
      username:
        claim: sub
        prefix: "dex:"
      groups:
        claim: groups
        prefix: "dex:"
AUTHCONFIG

echo "Creating us cluster..."
kind create cluster --name us --config "${US_CONFIG}"

echo "Verifying clusters..."
kubectl --context kind-hub get nodes
kubectl --context kind-us get nodes

echo "Extracting us cluster internal kubeconfig..."
kind get kubeconfig --name us --internal > "${ROOT_DIR}/tests/e2e/kubeconfig-us-internal"
US_INTERNAL_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' us-control-plane)
sed -i "s|https://us-control-plane:6443|https://${US_INTERNAL_IP}:6443|" "${ROOT_DIR}/tests/e2e/kubeconfig-us-internal"
kind get kubeconfig --name hub > "${ROOT_DIR}/tests/e2e/kubeconfig-hub"

echo "Testing cross-cluster reachability..."
docker exec us-control-plane ping -c1 "${HUB_IP}"

echo "Clusters ready."
echo "  hub context: kind-hub"
echo "  us context: kind-us"
echo "  us internal kubeconfig: hack/platform-mvp/kubeconfig-us-internal"
echo "  us auth config: ${US_AUTH_DIR}/authentication-configuration.yaml"