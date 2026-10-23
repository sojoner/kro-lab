# Phase 17 & 18 — Citizens & Seals: Identity and Credential Delivery

## What a Citizen Is

A Citizen represents a tenant **identity** — a human, workload, or automated agent that interacts with the Polis. It is the **subject** that holds Bindings and consumes Products.

Citizens are namespaced: the namespace IS the deme (tenant). The spec holds identity attributes (OIDC subject, SPIFFE URI for workload identities) and a list of allowed product names the citizen may bind.

| Field | Purpose |
|-------|---------|
| `spec.displayName` | Human-readable name |
| `spec.type` | Human, Workload, or Agent |
| `spec.oidcSub` | OIDC subject identifier (validated for no spaces) |
| `spec.x509SAN` | SPIFFE URI for workload mTLS identities |
| `spec.allowedProducts` | Product names this citizen is permitted to bind |

A Citizen lifecycle: **Pending** → **Active** → Suspended or Deactivated. The citizen-controller validates the OIDC subject format and activates the citizen.

## What a Seal Is

A Seal wraps **credential delivery** for a Binding. When a Binding is accepted, a Seal is created (manually or by automation). The seal-controller then:

1. Looks up the referenced Binding
2. Looks up the Offer behind that Binding
3. Generates a credential Secret (random password) in the consumer namespace
4. Updates the Seal phase to **Sealed**, recording the `credentialSecretRef`

A Seal can be **revoked**: the controller deletes the credential Secret and sets the phase to Revoked. A revoked Seal can be **reissued** by setting its phase back to Pending, triggering a fresh credential generation.

Seals are cluster-scoped. The revocation policy (Immediate or Graceful) determines whether the controller waits before deleting the Secret.

## Data Flow

```
Citizen (identity) → Binding (contract) → Offer (product terms) → Seal (credential wrapper) → Secret (actual credentials)
```

| Step | What Happens |
|------|-------------|
| 1. Citizen created | Controller validates OIDC sub, sets phase=Active |
| 2. Binding submitted | `contract-controller` validates against Offer, sets phase=Accepted |
| 3. Seal created (phase=Pending) | `seal-controller` generates Secret in consumer namespace, sets phase=Sealed |
| 4. Seal revoked (phase=Revoked) | `seal-controller` deletes Secret, records revokedAt |
| 5. Seal reissued (phase=Pending) | `seal-controller` generates a new Secret, sets phase=Sealed |

## CRDs

| CRD | Scope | Controller | File |
|-----|-------|-----------|------|
| `seals.agora.platform.example.com` | Cluster | `seal-controller/` | `crds/templates/seal-crd.yaml` |
| `citizens.agora.platform.example.com` | Namespaced | `citizen-controller/` | `crds/templates/citizen-crd.yaml` |

## Key Files

| File | Purpose |
|------|---------|
| `deploy/platform-mvp/chart/crds/templates/seal-crd.yaml` | Seal CRD |
| `deploy/platform-mvp/chart/crds/templates/citizen-crd.yaml` | Citizen CRD |
| `deploy/platform-mvp/chart/hub-services/templates/demo-citizen.yaml` | Demo Human citizen in default namespace |
| `platform-mvp/seal-controller/main.go` | Seal controller entry point |
| `platform-mvp/seal-controller/controller/reconciler.go` | Seal reconciler: create secret, revoke secret |
| `platform-mvp/citizen-controller/main.go` | Citizen controller entry point |
| `platform-mvp/citizen-controller/controller/reconciler.go` | Citizen reconciler: validate OIDC, activate |

## Acceptance

- **Seal CRD** is installed on hub via the `crds` Helm chart
- `kubectl get seals.agora.platform.example.com` works with printer columns
- `seal-controller` builds, starts, watches Seals
- Creating a Seal (phase=Pending) with a valid `bindingRef` pointing to an accepted Binding results in the controller creating a credential Secret and setting phase=Sealed
- Setting a Sealed seal's phase to Revoked triggers Secret deletion
- **Citizen CRD** is installed on hub via the `crds` Helm chart
- `kubectl get citizens.agora.platform.example.com` works with printer columns
- `citizen-controller` builds, starts, watches Citizens
- Creating a Citizen with a valid `oidcSub` (no spaces) results in phase=Active
- Creating a Citizen with an `oidcSub` containing spaces results in a Pending phase with an InvalidOIDCSub condition
- `go mod tidy && go build ./... && go vet ./...` passes for both controllers

## Next

Phase 19 will add the colony (environment) concept and platform-level policy enforcement across demes.