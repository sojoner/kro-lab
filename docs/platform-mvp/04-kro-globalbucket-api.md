# 04 — Kro GlobalWidget API

## Goal
Hub-only Kro RGD that expands one customer-facing object into per-region intents.

## Prerequisites
- Phase 3 complete
- Kro installed on hub

## Steps

```bash
# Register the RegionalWidgetRequest CRD first — kro resolves resource
# templates via API discovery, it does not auto-create CRDs for them.
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/regionalwidgetrequest-crd.yaml

# Grant kro's controller RBAC on the platform.example.com group — kro's
# default install only has permissions for its own CRDs (kro.run), not
# arbitrary custom API groups it generates CRDs for.
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/kro-rbac.yaml

# Apply the GlobalWidget ResourceGraphDefinition
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/globalwidget-rgd.yaml

# Create a test GlobalWidget
kubectl --context kind-hub apply -f - <<EOF
apiVersion: platform.example.com/v1alpha1
kind: GlobalWidget
metadata:
  name: my-widget
spec:
  regions: [us]
  message: "hello world"
EOF

# Verify RegionalWidgetRequest created
kubectl --context kind-hub get regionalwidgetrequest my-widget-us -o yaml
```

## Schema
- `spec.regions: []string` — regions to provision (us, eu, asia)
- `spec.message: string` — payload carried through to each region's Widget
- `status.regions` — CEL-aggregated from the `regionalWidgetRequest` collection

## Template
`forEach` over `spec.regions`, emits `RegionalWidgetRequest` per region with `region`, `message` fields. An empty `regions` list yields zero resources.

## Files produced
- `deploy/platform-mvp/kro/regionalwidgetrequest-crd.yaml`
- `deploy/platform-mvp/kro/kro-rbac.yaml`
- `deploy/platform-mvp/kro/globalwidget-rgd.yaml`

## Acceptance
- Applying a `GlobalWidget{regions:[us]}` produces exactly one `RegionalWidgetRequest`
- `chainsaw test tests/e2e --test 05-kro-globalwidget` passes