# 06-e2e-verification Spec
# Chainsaw-based cloud-native validation

## Goal
Prove full platform MVP loop using Chainsaw declarative tests.

## Acceptance Criteria
1. 01-hub-cluster-ready — hub has 1 node
2. 02-us-cluster-ready — us has 4 nodes
3. 03-rook-ceph-healthy — Ceph HEALTH_OK/HEALTH_WARN
4. 04-fleet-registration — ClusterProfile us exists
5. 05-kro-globalbucket — RegionalBucketRequest created
6. 06-binding-controller — CephObjectStoreUser + OBC on spoke
7. All Chainsaw tests pass from `tests/e2e/`