# 05 — Binding controller

## Goal
Standalone Go program watching `RegionalBucketRequest` on `hub`, creating Rook objects on the target `us` spoke.

## Architecture

```
hub cluster                        us cluster
┌──────────────────┐              ┌─────────────────────┐
│ RegionalBucket   │              │ CephObjectStoreUser │
│ Request          │◄─ watch ────►│ ObjectBucketClaim   │
│                  │  create      │                     │
│ status: regions  │◄─ propagate ─│ Secret (credentials)│
└──────────────────┘              └─────────────────────┘
```

## Controller logic

Two reconcilers share one `mcmanager.Manager` (real `sigs.k8s.io/multicluster-runtime`, provider `providers/cluster-inventory-api`):

1. **RegionalBucketReconciler** — hub-only watch (`mgr.GetLocalManager()`, plain controller-runtime builder) on `RegionalBucketRequest` (unstructured, Kro-generated CRD):
   - Read `.spec.region`
   - `mgr.GetCluster(ctx, region)` — on-demand spoke lookup via the provider (no engagement needed for this)
   - Create/upsert `CephObjectStoreUser` on spoke
   - Create/upsert `ObjectBucketClaim` on spoke
2. **StatusReconciler** — cross-cluster watch (`mcbuilder.ControllerManagedBy(mgr)`) on `ObjectBucketClaim` across every spoke cluster the provider engages. This is the actual multicluster-runtime fan-out: the provider discovers spoke clusters via `ClusterProfile` polling and calls `mgr.Engage(...)`, which is what lets this watch attach to a spoke cluster at all.
   - On OBC `Bound`: resolve its `ObjectBucket` (`spec.connection.endpoint`) and reference its credentials `Secret` (name/namespace only)
   - Propagate `{region, phase, endpoint, bucketName, secretRef}` to the matching `RegionalBucketRequest.status.regions` on hub

## Run

In-cluster (real deployment, via `chart/hub`): `make deploy-hub` builds the image, loads it into `kind-hub`, and installs a `Deployment` — no flags passed, so `main.go` falls back to in-cluster config for the hub and the `ClusterProfile`-based provider handles spoke discovery dynamically.

Local, out-of-cluster (manual/dev only):

```bash
cd platform-mvp/binding-controller
go run . --hub-kubeconfig ~/.kube/config --spoke-kubeconfig ../../hack/platform-mvp/kubeconfig-us-internal
```

## Packaging and deployment

- `platform-mvp/binding-controller/Dockerfile` — multi-stage build; **build context is the repo root**, not the module directory, since the module's `go.mod` has a local `replace` to the root module (`docker build -f platform-mvp/binding-controller/Dockerfile .`, or `make binding-controller-image`).
- `deploy/platform-mvp/chart/hub/templates/binding-controller.yaml` — `ServiceAccount`, `ClusterRole`/`ClusterRoleBinding` (hub-only: `regionalbucketrequests[/status]`, `clusterprofiles`, `secrets`), `Deployment`, and a `metrics` `Service` — all in the `default` namespace to match the pre-existing `ServiceMonitor` in `servicemonitors.yaml`.
- `deploy/platform-mvp/chart/hub/values.yaml` — `bindingController.{replicas,metricsPort,image,resources}`.
- `Makefile` — `make binding-controller-image` (build + `kind load docker-image`), a prerequisite of `deploy-hub`.

## Files produced
- `platform-mvp/binding-controller/main.go`
- `platform-mvp/binding-controller/controller/reconciler.go` (RegionalBucketReconciler)
- `platform-mvp/binding-controller/controller/status_reconciler.go` (StatusReconciler)
- `platform-mvp/binding-controller/controller/*_test.go`
- `platform-mvp/binding-controller/Dockerfile`
- `deploy/platform-mvp/chart/hub/templates/binding-controller.yaml`

## Acceptance
- Applying `GlobalBucket` produces `CephObjectStoreUser` + `ObjectBucketClaim` on spoke
- `RegionalBucketRequest.status.regions` populated with `{region, phase, endpoint, bucketName, secretRef}`
- `chainsaw test tests/e2e --test 06-binding-controller` passes **without** a manually-started local process — the controller runs as a `Deployment` brought up by `make deploy-hub`/Flux
