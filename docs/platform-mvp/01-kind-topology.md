# 01 — kind topology

## Goal
Two reachable kind clusters: `hub` and `us`.

## Prerequisites
- Docker, kind, kubectl installed

## Steps

```bash
# Create hub (1 control-plane)
kind create cluster --name hub --config deploy/platform-mvp/kind/kind-hub.yaml

# Create us (1 control-plane + 3 workers)
kind create cluster --name us --config deploy/platform-mvp/kind/kind-us.yaml

# Extract internal kubeconfig for cross-cluster access
kind get kubeconfig --name us --internal > hack/platform-mvp/kubeconfig-us-internal

# Verify cross-cluster reachability
HUB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-hub-control-plane)
docker exec kind-us-control-plane ping -c1 ${HUB_IP}
```

Or use the script:
```bash
./hack/platform-mvp/create-clusters.sh
```

## Files produced
- `deploy/platform-mvp/kind/kind-hub.yaml`
- `deploy/platform-mvp/kind/kind-us.yaml`
- `hack/platform-mvp/create-clusters.sh`
- `hack/platform-mvp/destroy-clusters.sh`

## Acceptance
- `kubectl --context kind-hub get nodes` — 1 node Ready
- `kubectl --context kind-us get nodes` — 4 nodes Ready
- Cross-cluster network connectivity verified
- `chainsaw test tests/e2e --test 01-hub-cluster-ready,02-us-cluster-ready` passes