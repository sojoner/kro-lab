# 05 — Binding controller

## Goal
Standalone Go program watching `RegionalWidgetRequest` on `hub`, creating Widget instances on the target `us` spoke.

## Architecture

```
hub cluster                        us cluster
┌──────────────────┐              ┌─────────────────────┐
│ RegionalWidget   │              │ Widget              │
│ Request          │◄─ watch ────►│  spec: { message }  │
│                  │  create      │  status: { ... }    │
│ status: regions  │◄─ propagate ─│                     │
└──────────────────┘              └─────────────────────┘
```

## Controller logic

1. **RegionalWidgetReconciler** — hub-only watch on `RegionalWidgetRequest`:
   - Read `.spec.region`
   - `mgr.GetCluster(ctx, region)` — on-demand spoke lookup via the provider
   - Create/upsert `Widget` on spoke

## Run

In-cluster (real deployment, via `chart/hub`): `make deploy-hub` builds the image, loads it into `kind-hub`, and installs a `Deployment` — no flags passed, so `main.go` falls back to in-cluster config for the hub and the `ClusterProfile`-based provider handles spoke discovery dynamically.

Local, out-of-cluster (manual/dev only):

```bash
cd platform-mvp/binding-controller
go run . --hub-kubeconfig ~/.kube/config --spoke-kubeconfig ../../hack/platform-mvp/kubeconfig-us-internal
```

## Packaging and deployment

- `platform-mvp/binding-controller/Dockerfile` — multi-stage build; **build context is the repo root**, not the module directory.
- `deploy/platform-mvp/chart/hub/templates/binding-controller.yaml` — `ServiceAccount`, `ClusterRole`/`ClusterRoleBinding`, `Deployment`, and a `metrics` `Service`.
- `deploy/platform-mvp/chart/hub/values.yaml` — `bindingController.{replicas,metricsPort,image,resources}`.
- `Makefile` — `make binding-controller-image` (build + `kind load docker-image`), a prerequisite of `deploy-hub`.

## Files produced
- `platform-mvp/binding-controller/main.go`
- `platform-mvp/binding-controller/controller/reconciler.go` (RegionalWidgetReconciler)
- `platform-mvp/binding-controller/controller/*_test.go`
- `platform-mvp/binding-controller/Dockerfile`
- `deploy/platform-mvp/chart/hub/templates/binding-controller.yaml`

## Acceptance
- Applying `GlobalWidget` produces `Widget` on spoke
- `RegionalWidgetRequest.status.regions` populated
- `chainsaw test tests/e2e --test 06-binding-controller` passes