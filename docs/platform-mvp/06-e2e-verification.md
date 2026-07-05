# 06 — E2E verification (Chainsaw)

## Goal
Prove the full loop using Chainsaw declarative tests.

## Test structure

```
tests/e2e/
├── .chainsaw.yaml                     # Multi-cluster config (hub + us)
├── tests/
│   ├── 01-hub-cluster-ready.yaml      # Assert hub has 1 node
│   ├── 02-us-cluster-ready.yaml       # Assert us has 4 nodes
│   ├── 03-rook-ceph-healthy.yaml      # Assert Ceph healthy + RGW running
│   ├── 04-fleet-registration.yaml     # Assert ClusterProfile registered
│   ├── 05-kro-globalbucket.yaml       # Assert GlobalBucket -> RegionalBucketRequest
│   └── 06-binding-controller.yaml     # Assert CephObjectStoreUser + OBC on spoke
```

## Run

```bash
# Full E2E (creates clusters, installs everything, runs Chainsaw)
./hack/platform-mvp/e2e.sh

# Or run Chainsaw directly (clusters must already exist)
chainsaw test tests/e2e/
```

## Acceptance
- All 6 Chainsaw tests pass
- Full E2E script exits 0