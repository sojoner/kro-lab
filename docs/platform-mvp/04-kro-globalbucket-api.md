# 04 — Kro GlobalBucket API

## Goal
Hub-only Kro RGD that expands one customer-facing object into per-region intents.

## Prerequisites
- Phase 3 complete
- Kro installed on hub

## Steps

```bash
# Register the RegionalBucketRequest CRD first — kro resolves resource
# templates via API discovery, it does not auto-create CRDs for them.
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/regionalbucketrequest-crd.yaml

# Grant kro's controller RBAC on the platform.example.com group — kro's
# default install only has permissions for its own CRDs (kro.run), not
# arbitrary custom API groups it generates CRDs for.
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/kro-rbac.yaml

# Apply the GlobalBucket ResourceGraphDefinition
kubectl --context kind-hub apply -f deploy/platform-mvp/kro/globalbucket-rgd.yaml

# Create a test GlobalBucket
kubectl --context kind-hub apply -f - <<EOF
apiVersion: platform.example.com/v1alpha1
kind: GlobalBucket
metadata:
  name: my-bucket
spec:
  regions: [us]
  sizeGiB: 10
  versioned: false
EOF

# Verify RegionalBucketRequest created
kubectl --context kind-hub get regionalbucketrequest my-bucket-us -o yaml
```

## Schema
- `spec.regions: []string` — regions to provision (us, eu, asia; validated per-region by the RegionalBucketRequest CRD's own enum, since kro's simple-schema doesn't support `enum` on array types)
- `spec.sizeGiB: int` — default 10
- `spec.versioned: bool` — default false
- `status.regions` — CEL-aggregated from the `regionalBucketRequest` collection (`${regionalBucketRequest.map(r, r.status)}`)

## Template
`forEach` over `spec.regions`, emits `RegionalBucketRequest` per region with `region`, `sizeGiB`, `versioned` fields. An empty `regions` list yields zero resources — no `includeWhen` guard is needed (kro's collections are empty-safe by design).

## Files produced
- `deploy/platform-mvp/kro/regionalbucketrequest-crd.yaml`
- `deploy/platform-mvp/kro/kro-rbac.yaml`
- `deploy/platform-mvp/kro/globalbucket-rgd.yaml`

## Acceptance
- Applying a `GlobalBucket{regions:[us]}` produces exactly one `RegionalBucketRequest`
- `chainsaw test tests/e2e --test 05-kro-globalbucket` passes