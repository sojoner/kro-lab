# Phase 13 — Polis: Vocabulary and Charter

The platform adopts the **Polis** metaphor: a city-state marketplace where providers and consumers meet in the Agora, bound by contracts, protected by seals. Every term maps to a concrete Kubernetes object — the metaphor is a naming aid, not an abstraction layer.

## API Group

```
agora.platform.example.com/v1alpha1
```

All new kinds (Product, Offer, Binding, Deme) live under this group. Existing kinds (GlobalWidget, RegionalWidgetRequest, Widget) remain under `platform.example.com/v1alpha1` for backward compatibility.

## Glossary

| Term | Meaning | Concrete object | Upstream analogue |
|---|---|---|---|
| **Polis** | The platform: hub + spokes + law | hub cluster, `ClusterProfile`s | openmcp Platform cluster; Platform Mesh `root` |
| **Agora** | Marketplace: what is offered, to whom | ORD document at `/.well-known/open-resource-discovery` | ORD Aggregator; PM `MarketplaceEntry` |
| **Stall** | A product offered by a vendor | `ResourceGraphDefinition` + `Product` metadata | ORD `Product`/`Package`; openmcp `ServiceProvider`+`ProviderConfig` |
| **Offer** | Provider's terms: versions, who may bind, what access it needs | `Offer` CRD | openmcp `ProviderConfig.versions`; PM `APIExportPolicy` + `permissionClaims` |
| **Contract** | Consumer's acceptance of an Offer | `Binding` CRD | PM `APIBinding`; ORD `ConsumptionBundle` |
| **Promise** | Provider's status back to consumer | `status.conditions` on the instance | all upstream |
| **Obligation** | Consumer-granted access (e.g. read this Secret) | accepted claims → RBAC/VAP | PM `permissionClaims`; openmcp `AccessRequest` |
| **Citizen** | An identity: human, workload, agent | OIDC user; projected SA token; Dex `client_credentials` client | openmcp `iam.oidc/tokens`; PM Keycloak+OpenFGA |
| **Seal** | Secret/key binding rules to identities | per-tenant key; credential `Secret` in consumer namespace | OpenKCM KeyConfig→System; PM `secrets` claim |
| **Law** | Admission and authorization policy | `ValidatingAdmissionPolicy`, RBAC | OpenKCM Cedar; PM OpenFGA |
| **Deme** | Tenant / account | `platform.example.com/tenant` label → namespace | openmcp `Project`→`Workspace`; PM `Account` |
| **Colony** | A spoke region | `ClusterProfile/us` | openmcp `Cluster`; PM provider runtime cluster |

## Product CRD

`Product` is a lightweight metadata object — the heavy lifting is done by the RGD. One `Product` references one RGD.

```yaml
apiVersion: agora.platform.example.com/v1alpha1
kind: Product
metadata:
  name: widget
spec:
  displayName: "Widget"
  vendor: acme-corp
  description: >
    Minimal end-to-end demonstration product. Proves the hub→spoke
    fulfilment pattern works end-to-end with identity, multi-tenancy,
    and fail-closed auth.
  labels:
    cost-tier: demo
    sla: none
  rgdRef:
    name: globalwidget.platform.example.com
  versions:
    - version: v1alpha1
      releaseStatus: active
  visibility: public
status:
  conditions:
    - type: Ready
      status: "True"
  schemaVersion: v1alpha1
```

Prestige products — candidates for Phase 14 — should have:
- An RGD with real spoke-side resources (operator + CRD that does observable work)
- Not dependent on large operators (CNPG, etc.) that wouldn't fit in kind
- Demonstrable in a Chainsaw test

Candidates: `Queue` (NATS, minimal operator), `Database` (CloudNativePG, requires operator Helm chart), `ObjectStore` (MinIO).

## Product Inventory

| Product | Vendor | RGD | Status | Runtime |
|---|---|---|---|---|
| Widget | acme-corp | `globalwidget.platform.example.com` | active | widget-operator (existing) |
| Queue | acme-corp | TBD | proposed | NATS (kind-runnable) |
| Database | globex-inc | TBD | proposed | CloudNativePG |
| ObjectStore | globex-inc | TBD | proposed | MinIO operator |

The Widget stays as the original guinea pig. The others are added in Phase 14.

## Acceptance

- `docs/platform-mvp/13-polis-glossary.md` exists and is referenced from `00-overview.md` Phase Index
- `Product` CRD is installed by the `crds` Helm chart and passes `kubectl explain`
- The Widget `Product` is created → Chainsaw test `tests/e2e/tests/13-product-crd/`
- All existing tests (01–12, 15–21) still pass

## Key Files

| File | Purpose |
|---|---|---|
| `deploy/platform-mvp/chart/crds/templates/product-crd.yaml` | Product CRD |
| `deploy/platform-mvp/chart/crds/templates/widget-product.yaml` | Widget Product instance (post-install) |
| `tests/e2e/tests/13-product-crd/chainsaw-test.yaml` | E2E validation |