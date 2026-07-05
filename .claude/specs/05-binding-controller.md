# 05-binding-controller Spec
# RED phase — tests before implementation

## Goal
Standalone Go controller using multicluster-runtime to bind Kro-expanded intents to Rook spoke clusters.

## Acceptance Criteria
1. Reconciler creates CephObjectStoreUser on spoke for each RegionalBucketRequest
2. Reconciler creates ObjectBucketClaim on spoke
3. Unknown region returns error
4. Uses the real `sigs.k8s.io/multicluster-runtime` (`mcmanager.Manager`, `mcbuilder`), not a hand-rolled look-alike — `providers/cluster-inventory-api` implements the real `multicluster.Provider` and dynamically engages spoke clusters discovered via `ClusterProfile`
5. Status propagation: RegionalBucketRequest.status.regions populated with full `{region, phase, endpoint, bucketName, secretRef}` from spoke state (via a second, spoke-side watch on ObjectBucketClaim — the actual multicluster-runtime fan-out, not a synchronous hub-only lookup)
6. All Go tests pass (TDD)
7. Packaged and deployed, not just runnable locally: container image built from `platform-mvp/binding-controller/Dockerfile`, run as a `Deployment` (with `ServiceAccount`/RBAC and a `metrics` `Service`) via `chart/hub`, so `make deploy-hub`/Flux bring it up automatically — no manual `go run .` required for chainsaw test `06-binding-controller` to pass
8. `providers/cluster-inventory-api`'s `ClusterProfileGVK` matches the actually-installed CRD group/version (`multicluster.x-k8s.io/v1alpha1`), verified by a test asserting against the real group — not just internal self-consistency
