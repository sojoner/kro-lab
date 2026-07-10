# 05-binding-controller Spec
# RED phase — tests before implementation

## Goal
Standalone Go controller using multicluster-runtime to bind Kro-expanded intents to a `Widget` on the spoke cluster.

## Acceptance Criteria
1. Reconciler creates a `Widget` on spoke for each `RegionalWidgetRequest`, carrying `.spec.message` through
2. Unknown region returns error
3. Uses the real `sigs.k8s.io/multicluster-runtime` (`mcmanager.Manager`, `mcbuilder`), not a hand-rolled look-alike — `providers/cluster-inventory-api` implements the real `multicluster.Provider` and dynamically engages spoke clusters discovered via `ClusterProfile`
4. Status propagation: `RegionalWidgetRequest.status.regions` populated with full `{region, phase, endpoint}` from spoke state (via a second, spoke-side watch on `Widget` — the actual multicluster-runtime fan-out, not a synchronous hub-only lookup)
5. All Go tests pass (TDD)
6. Packaged and deployed, not just runnable locally: container image built from `platform-mvp/binding-controller/Dockerfile`, run as a `Deployment` (with `ServiceAccount`/RBAC and a `metrics` `Service`) via `chart/hub`, so `make deploy-hub`/Flux bring it up automatically — no manual `go run .` required for chainsaw test `06-binding-controller` to pass
7. `providers/cluster-inventory-api`'s `ClusterProfileGVK` matches the actually-installed CRD group/version (`multicluster.x-k8s.io/v1alpha1`), verified by a test asserting against the real group — not just internal self-consistency
