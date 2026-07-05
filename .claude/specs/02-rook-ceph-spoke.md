# 02-rook-ceph-spoke Spec
# RED phase — define what must be true before implementation starts

## Goal
Real S3-compatible endpoint on `us` via Rook-managed Ceph RGW using loop-device-backed block storage.

## Acceptance Criteria
1. `kubectl --context kind-us -n rook-ceph exec deploy/rook-ceph-tools -- ceph status` shows HEALTH_OK or HEALTH_WARN
2. OSDs are `up`/`in`
3. RGW service reachable in-cluster: `kubectl --context kind-us -n rook-ceph get svc rook-ceph-rgw-my-store`
4. Manual bucket creation via toolbox succeeds (radosgw-admin bucket list or s3cmd/awscli)
5. If OSDs never come up: fallback to single worker + single loop device + mon.count:1, osd count:1