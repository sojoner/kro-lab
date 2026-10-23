# Phase 19 — Demes: Tenant Accounts

## What a Deme Is

A Deme is a **tenant account** in the Polis. It maps directly to a Kubernetes namespace and carries labels, resource quotas, and an allow-list of products the tenant may access.

Each Deme is a cluster-scoped CRD (`demes.agora.platform.example.com`) — not namespaced — because it is a tenant registration that controls the creation and management of a dedicated namespace.

| Field | Purpose |
|-------|---------|
| `spec.displayName` | Human-readable tenant name |
| `spec.namespaceName` | The Kubernetes namespace this deme owns |
| `spec.quota` | Resource limits: cpu, memory, storage |
| `spec.allowedProducts` | Product names this deme is permitted to bind |
| `spec.labels` | Key-value pairs applied to the managed namespace |
| `spec.contactEmail` | Administrative contact for the tenant |

## Relationship to Citizen and Binding

A Deme represents the **tenant scope** (the container). Citizens and Bindings live inside that scope:

```
Deme (tenant → namespace)
 ├── Citizen (identity: Human/Workload/Agent)
 │    └── Binding (contract with an Offer)
 │         └── Seal (credential wrapper)
 └── Namespace (Kubernetes isolation boundary)
```

The Deme's `allowedProducts` field acts as a **policy gate** — even if a Citizen requests a Binding, the Deme must explicitly permit the product. The Deme's `namespaceName` is where the Citizen resources and resulting Bindings exist.

## Deme Lifecycle

| Phase | Meaning |
|-------|---------|
| **Pending** | Deme created; not yet processed |
| **Creating** | Controller is provisioning the namespace |
| **Active** | Namespace exists, Deme is operational |
| **Suspended** | Deme access is temporarily disabled |
| **Terminating** | Deme is being removed; namespace preserved for admin cleanup |

The controller flow:

1. On Deme create (phase=**Pending**):
   1. Validate `spec.namespaceName` is present
   2. Create the namespace if it doesn't exist
   3. Apply Deme labels to the namespace
   4. Set phase=**Active**
   5. Count product bindings for this tenant (set `status.productCount`)

2. On Deme delete:
   1. Set phase=**Terminating**
   2. **Do NOT** delete the namespace — that is an intentional admin-level operation

## CRD and Controller

| Artifact | Location |
|----------|----------|
| Deme CRD | `deploy/platform-mvp/chart/crds/templates/deme-crd.yaml` |
| Deme controller | `platform-mvp/deme-controller/` |
| Demo instance | `deploy/platform-mvp/chart/hub-services/templates/demo-deme.yaml` |

## Key Files

| File | Purpose |
|------|---------|
| `deploy/platform-mvp/chart/crds/templates/deme-crd.yaml` | CRD schema |
| `platform-mvp/deme-controller/main.go` | Controller entrypoint |
| `platform-mvp/deme-controller/controller/reconciler.go` | Reconciler: namespace management, product counting |
| `deploy/platform-mvp/chart/hub-services/templates/demo-deme.yaml` | Demo Deme (demo-corp in default namespace) |

## Acceptance

- Deme CRD is installed on the hub
- `kubectl get demes.agora.platform.example.com` shows printer columns (Namespace, Phase, Products, Age)
- `deme-controller` builds, starts, watches Demes
- Creating a Deme (namespaceName="default") results in:
  - Namespace "default" exists (or is updated with labels)
  - Deme phase=Active
  - `status.productCount` reflects active Offer/Bindings in that namespace
- Deleting a Deme sets phase=Terminating but does NOT delete the namespace
- `go mod tidy && go build ./... && go vet ./...` passes for the deme-controller

## Next

Phase 20 will add the Colony concept for multi-region ORD aggregation.
