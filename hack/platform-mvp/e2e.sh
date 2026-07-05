#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTS_DIR="${ROOT_DIR}/tests/e2e"

echo "==> Phase 1: Creating kind clusters"
"${SCRIPT_DIR}/create-clusters.sh"

echo "==> Phase 2: Installing Rook/Ceph on us"
"${SCRIPT_DIR}/attach-loop-devices.sh"
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/crds.yaml
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/common.yaml
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/operator.yaml
kubectl --context kind-us apply -f "${ROOT_DIR}/deploy/platform-mvp/rook/cluster.yaml"
echo "Waiting for CephCluster..."
kubectl --context kind-us -n rook-ceph wait --for=condition=Ready cephcluster/rook-ceph --timeout=5m || true
kubectl --context kind-us apply -f "${ROOT_DIR}/deploy/platform-mvp/rook/object-store.yaml"
echo "Waiting for CephObjectStore..."
kubectl --context kind-us -n rook-ceph wait --for=condition=Ready cephobjectstore/my-store --timeout=2m || true

echo "==> Phase 3: Registering fleet on hub"
kubectl --context kind-hub apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-inventory-api/main/config/crd/bases/cluster.x-k8s.io_clusterprofiles.yaml
"${SCRIPT_DIR}/register-fleet.sh"

echo "==> Phase 4: Installing Kro on hub"
kubectl --context kind-hub apply -f "${ROOT_DIR}/deploy/platform-mvp/kro/globalbucket-rgd.yaml"

echo "==> Phase 5: Running binding controller"
(cd "${ROOT_DIR}/platform-mvp/binding-controller" && \
    go run . --hub-kubeconfig "${HOME}/.kube/config" --spoke-kubeconfig "${SCRIPT_DIR}/kubeconfig-us-internal" &)
BC_PID=$!
trap "kill ${BC_PID} 2>/dev/null || true" EXIT
sleep 5

echo "==> Phase 6: Running Chainsaw E2E tests"
KUBECONFIG_HUB="${HOME}/.kube/config" KUBECONFIG_US="${SCRIPT_DIR}/kubeconfig-us-internal"
cp "${KUBECONFIG_HUB}" "${TESTS_DIR}/kubeconfig-hub"
cp "${KUBECONFIG_US}" "${TESTS_DIR}/kubeconfig-us-internal"

chainsaw test "${TESTS_DIR}" "$@" || {
    echo "Chainsaw tests failed"
    exit 1
}

echo "==> E2E verification complete"