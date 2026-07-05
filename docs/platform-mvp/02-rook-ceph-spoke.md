# 02 — Rook/Ceph spoke

## Goal
Real S3-compatible endpoint on `us` via Rook-managed Ceph RGW with loop-device-backed storage.

## Prerequisites
- Phase 1 complete (us cluster running with 3 workers)
- Rook v1.16.5 operator installed

## Steps

```bash
# Attach loop devices to us worker nodes
./hack/platform-mvp/attach-loop-devices.sh

# Install Rook CRDs + operator
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/crds.yaml
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/common.yaml
kubectl --context kind-us create -f https://raw.githubusercontent.com/rook/rook/v1.16.5/deploy/examples/operator.yaml

# Apply CephCluster (mon:1, mgr:1, single-replica, loop devices)
kubectl --context kind-us apply -f deploy/platform-mvp/rook/cluster.yaml

# Wait for Ceph healthy
kubectl --context kind-us -n rook-ceph wait --for=condition=Ready cephcluster/rook-ceph --timeout=10m

# Apply CephObjectStore (RGW)
kubectl --context kind-us apply -f deploy/platform-mvp/rook/object-store.yaml

# Wait for RGW ready
kubectl --context kind-us -n rook-ceph wait --for=condition=Ready cephobjectstore/my-store --timeout=5m

# Verify ceph status
kubectl --context kind-us -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

## Fallback
If OSDs don't come up: reduce to single worker + single loop device + `mon.count: 1`, `osd count: 1`.

## Files produced
- `hack/platform-mvp/attach-loop-devices.sh`
- `deploy/platform-mvp/rook/cluster.yaml`
- `deploy/platform-mvp/rook/object-store.yaml`

## Acceptance
- `ceph status` shows HEALTH_OK or HEALTH_WARN
- OSDs up/in
- RGW service reachable: `kubectl --context kind-us -n rook-ceph get svc rook-ceph-rgw-my-store`
- `chainsaw test tests/e2e --test 03-rook-ceph-healthy` passes