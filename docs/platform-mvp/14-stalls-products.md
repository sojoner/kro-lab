# Phase 14 — Stalls: Products from RGDs

A Product in the Polis is a kro `ResourceGraphDefinition` plus metadata. The RGD defines the consumer API and the downstream orchestration. The metadata makes it discoverable, licensable, and traceable — the same RGD, given a different vendor and `releaseStatus`, is a different Product.

## Design

One `Product` → one RGD. The RGD does the heavy lifting (CRD generation, controller fan-out, status aggregation). `Product` is thin — it holds the ORD-required fields that have no home in the RGD spec: vendor, versions, visibility, labels, policy levels, consumption bundles.

```yaml
apiVersion: agora.platform.example.com/v1alpha1
kind: Product
metadata:
  name: widget
  labels:
    agora.platform.example.com/vendor: acme-corp
spec:
  displayName: "Widget"
  vendor: acme-corp
  description: >
    Minimal end-to-end demonstration product.
  rgdRef:
    name: globalwidget.platform.example.com
  versions:
    - version: v1alpha1
      releaseStatus: active
  visibility: public
```

The `rgdRef.name` is the name of an existing `ResourceGraphDefinition` — no cross-reference validation at admission (kro RGDs are not CRDs), just a string.

## Product Inventory (Planned)

| Product | Vendor | RGD | Runtime on spoke | Status |
|---|---|---|---|---|
| Widget | acme-corp | `globalwidget.platform.example.com` | widget-operator | active |
| Queue | acme-corp | `queue.platform.example.com` | NATS (embedded) | proposed |
| Database | globex-inc | `database.platform.example.com` | CloudNativePG | proposed |
| ObjectStore | globex-inc | `objectstore.platform.example.com` | MinIO | proposed |

Product selection criteria: the spoke-side resource must do observable, testable work (write data, serve an endpoint, produce a metric), and must not require per-node DaemonSets or CSI drivers that kind cannot support.

## Catalog Controller

A new hub-side controller (`platform-mvp/catalog-controller`) watches `Product` objects and renders an ORD 1.16 document. It exposes `/.well-known/open-resource-discovery` on port 8080.

```
Product CRDs (hub)
     │
     ▼
catalog-controller ──► OrdDocument (in-memory)
     │
     ▼
/.well-kown/open-resource-discory
```

**Two perspectives** (future):
- `system-version` — the catalog view: what Products exist, regardless of whether any are instantiated.
- `system-instance` — the runtime view: which tenant has a Binding for which Product, and what is the instance status.

## Deployment

Catalog-controller is not currently deployed as a Helm chart — it runs locally for development against a running hub cluster:

```bash
go run ./platform-mvp/catalog-controller --kubeconfig ~/.kube/config
curl http://localhost:8080/.well-known/open-resource-discovery | jq
```

## Acceptance

- `Product` CRD is installed on hub via the `crds` Helm chart (`product-crd.yml`)
- Widget `Product` is created → `kubectl get products.agora.platform.example.com widget` returns the Widget product
- `catalog-controller` starts, watches Products, produces a valid ORD 1.16 JSON document
- Document contains at least one vendor (acme-corp), one product (widget), one package, one API resource
- `/.well-known/open-resource-discovery` returns 200 with JSON
- Chainsaw test `tests/e2e/tests/14-product-catalog/` validates the ORD document schema

## Key Files

| File | Purpose |
|------------|---------|
| `deploy/platorm-mvp/chart/crds/templates/product-crd.yml` | Product CRD |
| `deploy/platform-mvp/chart/hub-services/tempates/widet-product.yaml` | Widget Product instance |
| `platform-mv/catalog-contoller/main.go` | Catalog controller entry point |
| `platform-mvp/catlog-controller/controller/orwriter.go` | ORD document model + I/O |
| `platorm-mvp/catalog-controller/controller/econciler.go`| Product watcher → ORD builder |

## Next

Phase 15 adds a Chainsaw test that validates the catalog output against `@open-resource-discovery/specification` JSON schema and the ORD Provider configuration endpoint (`/.well-known/open-resource-discovery` returning the document list).