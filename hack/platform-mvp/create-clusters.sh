#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HUB_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-hub.yaml"
US_CONFIG_TMPL="${ROOT_DIR}/deploy/platform-mvp/kind/kind-us.yaml.tmpl"
US_CONFIG="${ROOT_DIR}/deploy/platform-mvp/kind/kind-us.yaml"
US_CHART="${ROOT_DIR}/deploy/platform-mvp/chart/us"
# Readable/writable by the invoking user (no root-owned /tmp race, survives
# host reboots) — always resolved relative to US_CONFIG_TMPL's own location,
# never a machine-specific absolute path.
US_AUTH_DIR="$(dirname "${US_CONFIG_TMPL}")/us-auth"

echo "Creating hub cluster..."
kind create cluster --name hub --config "${HUB_CONFIG}"

HUB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hub-control-plane)

echo "Rendering kind-us.yaml from template (extraMounts hostPath -> ${US_AUTH_DIR})..."
mkdir -p "${US_AUTH_DIR}"
sed "s|__US_AUTH_DIR__|${US_AUTH_DIR}|" "${US_CONFIG_TMPL}" > "${US_CONFIG}"

echo "Preparing us AuthenticationConfiguration from chart/us/templates/auth-config.yaml (single source of truth, see chart/us/values.yaml)..."
"${SCRIPT_DIR}/render-us-auth-config.sh" "${US_CHART}" > "${US_AUTH_DIR}/authentication-configuration.yaml"

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