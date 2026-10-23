# Design: Polis — Platform-as-Products Study Roadmap

**Status:** Proposal | **Builds on:** `oidc-trust-v2.md`, Phases 00–12 | **Date:** 2026-09-26

## 1. Thesis

kro-lab today proves *one* thing: a hub can generate regional intent from a kro RGD and fulfil it on spokes under a fail-closed identity model (`README.md:9-19`). It has no notion of a product, an offer, a contract, or a catalog. "Widget" is a placeholder (`docs/platform-mvp/04-kro-downstream-orchestration.md:3`).

The next study asks: **can one RGD be the single source of truth for a platform product** — its consumer API, its catalog entry, its contract terms, its credential binding, and its multi-cluster fulfilment — using only projects that exist today in the NeoNephos / ApeiroRA ecosystem?

```
                RGD (kro)  =  Product definition
                    │
    ┌───────────────┼────────────────┬──────────────────┐
    ▼               ▼                ▼                  ▼
  CRD            ORD document     Offer/Binding      ClusterRequest /
  (consumer      (catalog,        (contract:         RegionalRequest
   API)           /.well-known)    claims, RBAC,      (fulfilment,
                                   secrets)           multicluster-runtime)
```

## 2. Metaphor: the Polis

The city-state (Polis) is the platform. Its Agora is the marketplace where providers and consumers meet, bound by contracts, protected by seals, governed by law. Every term maps to a concrete Kubernetes object — the metaphor is a naming aid, not a layer.

| Polis term | Meaning | Concrete object(s) | Upstream analogue |
|---|---|---|---|
| **Polis** | The platform: hub + spokes + law | hub cluster, `ClusterProfile`s | openmcp Platform cluster; Platform Mesh `root` |
| **Agora** | Marketplace: what is offered, to whom | ORD document at `/.well-known/open-resource-discovery` | ORD Aggregator; Platform Mesh `MarketplaceEntry` |
| **Stall** | A product offered by a vendor | `ResourceGraphDefinition` + `Product` metadata | ORD `Product`/`Package`; openmcp `ServiceProvider`+`ProviderConfig`; PM `APIExport`+`ProviderMetadata` |
| **Offer** | Provider's terms: versions, who may bind, what access it needs | `Offer` CRD (new) | openmcp `ProviderConfig.versions`; PM `APIExportPolicy` + `permissionClaims` |
| **Contract** | Consumer's acceptance of an Offer | `Binding` CRD (new) | PM `APIBinding` (accepted claims); ORD `ConsumptionBundle` |
| **Promise** | Provider's status back to consumer | `status.conditions` on instance | all three |
| **Obligation** | Consumer-granted access (e.g. read this Secret) | accepted claims → RBAC/VAP | PM `permissionClaims`; openmcp `AccessRequest` |
| **Citizen** | An identity: human, workload, agent | OIDC user; projected SA token; `client_credentials` client | openmcp `iam.oidc/tokens`; PM Keycloak+OpenFGA |
| **Seal** | Secret/key binding rules to identities | per-tenant key; credential `Secret` in consumer ns | OpenKCM KeyConfig→System; PM `secrets` claim |
| **Law** | Admission and authorization policy | `ValidatingAdmissionPolicy`, RBAC | OpenKCM Cedar; PM OpenFGA; openmcp VAP |
| **Deme** | Tenant / account | `platform.example.com/tenant` label → namespace | openmcp `Project`→`Workspace`; PM `Account` |
| **Colony** | A spoke region | `ClusterProfile/us` | openmcp `Cluster`; PM provider runtime cluster |

Term "Greek Police" in the brief is read as **Polis**.

## 3. Upstream assessment (verified 2026-09-26)

| Project | Stage | What it gives us | Hard truth |
|---|---|---|---|
| **OpenControlPlane / openmcp** | v1.4.1, monthly releases, most mature | `ClusterRequest`/`AccessRequest`/`ClusterProvider` model; `service-provider-kro` (kro *as a service*); `multicluster-provider` for multicluster-runtime; `Project`→`Workspace`→`ControlPlane` tenancy | Its `ClusterProfile` (`clusters.openmcp.cloud`) is **not** SIG `multicluster.x-k8s.io/ClusterProfile` — name clash with our provider. Marketplace / entitlement API is explicitly WIP (backlog #384). |
| **Platform Mesh** | 0.5.2, alpha, breaking changes | The actual "Agora": `APIExport`→`APIBinding`, permission claims as contract, ReBAC via OpenFGA, `MarketplaceEntry` | Requires kcp + Keycloak + OpenFGA + Luigi portal (8 GB RAM). Adopting it wholesale turns kro-lab into a Platform Mesh demo. No ORD wiring; OpenKCM wiring is Q4-2026 roadmap. |
| **Open Resource Discovery** | Spec 1.16, production at SAP | Machine-readable catalog: `Vendor`→`Product`→`Package`→`APIResource`; `visibility`, `releaseStatus`, `ConsumptionBundle.credentialExchangeStrategies` | **Zero Kubernetes integration**; pull-only; models discovery, not ordering. A K8s→ORD projection has to be built — that is the novel contribution. |
| **OpenKCM** | cmk 0.9.0 / krypton 0.1.0, pre-1.0 | Tiered envelope encryption L1 (customer KMS) → L2 tenant → L3 service → L4 DEK; identity-bound key authorization; kill switch | Consumer path is KMIP/gRPC + mTLS x509, no Secret/CSI/ESO integration; several ADRs are titles only; `krypton-operator` experimental. |
| **kro** | v0.9.2 (ours); openmcp ships RGDs per component | RGD as product template; CEL status aggregation; `forEach` fan-out | No catalog/metadata hooks — we add them via annotations/`Product`. |

Common ground worth exploiting: all four ApeiroRA projects agree on **KRM as lingua franca**, **Flux + OCM** for delivery, **OIDC for humans / SA-or-x509 for workloads**, and **Secret-in-requester-namespace** for credential delivery. kro-lab already conforms to the last two.

## 4. Roadmap

Each phase yields one demonstrable claim, one Chainsaw test directory, one doc under `docs/platform-mvp/`. Phases are ordered by *value per RAM* on kind; later phases are optional bridges.

### Phase 13 — Charter and vocabulary

- Adopt the §2 glossary; add `docs/platform-mvp/13-polis-glossary.md`.
- API group for new kinds: `agora.platform.example.com/v1alpha1`.
- Replace `GlobalWidget` as the flagship: keep it as the smoke test, add two real products from two "vendors" so the market has more than one stall.
- **Claim:** the repo speaks one vocabulary across docs, CRDs, labels, metrics.

### Phase 14 — Stalls: products from RGDs

- `Product` CRD (or RGD annotations `agora.platform.example.com/{vendor,product,package,releaseStatus,visibility}`) carrying ORD-required metadata.
- Two products, both runnable in kind: e.g. `Queue` (NATS) from vendor `acme`, `Database` (CloudNativePG) from vendor `globex`. Each is an RGD whose fan-out reuses the existing `RegionalWidgetRequest` → binding-controller path, generalised to `RegionalRequest{kind, spec}`.
- **Claim:** adding a product = adding one RGD + one metadata object; no controller code.

### Phase 15 — Agora: ORD catalog generated from the hub

- `catalog-controller` (Go, TDD): watches RGDs + `Product`, renders ORD 1.16 document: `vendors[]`, `products[]`, `packages[]`, `apiResources[]` with `resourceDefinitions` pointing at the kro-generated CRD OpenAPI schema (`apiProtocol: rest`, custom `implementationStandard: kro:rgd:v1`).
- Serves `/.well-known/open-resource-discovery` on the hub ingress. Two perspectives: `system-version` (catalog) and `system-instance` (per-tenant instances, from `Binding`s and instance status).
- Chainsaw validates output against `@open-resource-discovery/specification` JSON schema; optionally run the upstream `provider-server` or `explorer` UI against it.
- **Claim:** the platform is discoverable by any ORD aggregator without a bespoke UI.

### Phase 16 — Contracts: Offer and Binding

- `Offer` (provider side): `productRef`, `versions[]`, `allowTenants` (path/label expressions), `requestedClaims[]` (`{group, resource, verbs, selector}`), `credentialDelivery: {secretName template}`. Mirrors openmcp `ProviderConfig` + Platform Mesh `APIExportPolicy` + `permissionClaims`.
- `Binding` (consumer side): `offerRef`, `version`, `acceptedClaims[]`. Effective access = intersection; new claims not auto-accepted. Mirrors `APIBinding`.
- Enforcement: `ValidatingAdmissionPolicy` deny-by-default — a tenant may create a product instance only if a `Binding` exists in its namespace; the binding-controller acts on behalf of the provider only within accepted claims (RBAC generated from `Binding`).
- ORD: `consumptionBundles[]` per Offer with `credentialExchangeStrategies[{type: custom, customType: "agora:binding-secret:v1", callbackUrl}]`; `integrationDependencies[]` emitted for consumers.
- **Claim:** contract terms are declarative, auditable, and enforced at admission — not in controller code.

### Phase 17 — Citizens: humans, workloads, agents

- Keep the split model from `oidc-trust-v2.md`. Add the third leg explicitly: **agents** as Dex `client_credentials` clients with audience-bound tokens, `claimValidationRules` on spokes, and a `security.platform.example.com/identity: agent` label. An agent may hold a `Binding` on behalf of a tenant only if named in `Offer.allowAgents`.
- Workload identity for Phase 18: cert-manager–issued x509 with `SPIFFE`-style URI SAN `spiffe://polis/ns/<tenant>/sa/<name>`, so subjects can be listed in OpenKCM `extauthz` `trustedSubjects`. Evaluate SPIRE only if cert-manager proves insufficient.
- Authorization decision: stay RBAC + VAP. Evaluate OpenFGA (Platform Mesh pattern) only if the demo needs relationship inheritance (org→deme→binding). Record as ADR.
- **Claim:** three identity types, one policy model, no shared credentials.

### Phase 18 — Seals: keys and secrets

- **18a (foundation):** OpenBao (transit) + External Secrets Operator. One transit key per tenant. Binding credentials are envelope-encrypted with the tenant key and delivered as a `Secret` into the consumer namespace under an accepted `secrets` claim.
- **18b (OpenKCM):** deploy `openkcm/cmk` + `openkcm/krypton` via Helm with the OpenBao Transit keystore plugin. `keychain-bridge` controller maps `Deme` → Registry `Tenant`/`System`, creates a `KeyConfig`, connects System→KeyConfig; L3 service key wraps binding secrets. Workload→Krypton via mTLS with Phase 17 certs. Demo the **kill switch**: disable L1 → all tenant credentials become undecryptable, `Binding` conditions flip to `SealRevoked`.
- **Claim:** secrets are the seals — revoke a tenant's root key and every contract it holds is void, cryptographically.

### Phase 19 — Colonies: openmcp-compatible fulfilment

- Run `openmcp-operator` + `cluster-provider-kind` on the hub. Register our spokes as openmcp `Cluster`s; let `AccessRequest` mint the spoke kubeconfig instead of our Makefile secret (`Makefile:350-352`).
- Replace or wrap `providers/cluster-inventory-api` with openmcp `multicluster-provider`; keep the SIG `ClusterProfile` as the *inventory* view and openmcp `Cluster` as the *lifecycle* view. Document the name clash as an ADR.
- Package each Product as an openmcp **ServiceProvider** using `service-provider-template` / `opencontrolplane-runtime`, so a tenant `ControlPlane` + `Kro` service + our RGDs yields the same products inside an MCP.
- **Claim:** the same Product is orderable via the hub *and* via an OpenControlPlane `ControlPlane`; fulfilment is substrate-independent.

### Phase 20 — Bridge to the Agora (Platform Mesh / kcp) — stretch

- Expose Products as kcp `APIExport` via `api-syncagent`; generate `ProviderMetadata` from the same `Product` object that feeds ORD. Consumer `APIBinding` ⇄ our `Binding` (one-way sync first).
- **Claim:** Offer/Binding is a portable contract model; the kcp substrate is an implementation detail.

## 5. Decision points (record as ADRs in `docs/adr/`)

| # | Fork | Recommendation | Why |
|---|---|---|---|
| 1 | Vanilla K8s `Offer`/`Binding` vs adopt Platform Mesh/kcp | Vanilla first (Ph 16), bridge later (Ph 20) | keeps the study kind-sized; proves the model, not the substrate |
| 2 | RBAC+VAP vs OpenFGA ReBAC | RBAC+VAP | already fail-closed; ReBAC only pays off with deep hierarchy |
| 3 | ESO+OpenBao vs OpenKCM direct | ESO+OpenBao first (18a), OpenKCM as swap (18b) | OpenKCM has no Secret path; the interface must exist before the vendor |
| 4 | Own catalog vs ORD | ORD | standard, aggregator-ready, and unclaimed territory for K8s |
| 5 | Own fleet API vs openmcp `Cluster`/`AccessRequest` | Wrap openmcp (Ph 19) | most mature of the four; already ships `service-provider-kro` |

## 6. Risks

- **RAM on kind**: openmcp + OpenBao + OpenKCM + LGTM exceeds a laptop. Mitigate with per-phase `make` profiles and `kind` cluster reuse; consider dropping Loki/promtail in product phases.
- **Alpha churn**: Platform Mesh (breaking changes), OpenKCM (krypton restarted from scratch 2025-11), openmcp API groups mid-rename (`openmcp.cloud` → `open-control-plane.io`). Pin versions in `Makefile`; test with Chainsaw.
- **ORD has no push transport**: catalog freshness is pull-based; document polling interval as config.
- **Two `ClusterProfile`s**: SIG vs openmcp. Must be explicit in code and docs or the provider will silently watch the wrong kind.
- **Scope creep**: the metaphor invites endless naming. Rule: no Polis term without a row in §2 and a concrete object.

## 7. Existing gaps to close before Phase 13

From the repo survey — cheap, and they undermine credibility of a "platform" demo:

- `deploy/platform-mvp/flux/helmrepositories.yaml:26` — missing `---` newline merges two HelmRepositories.
- `docs/platform-mvp/01-kind-topology.md:14-19` — says 3 workers; `kind-us.yaml:21-22` has 1.
- `docs/platform-mvp/04-kro-downstream-orchestration.md:52-68` — old `forEach` syntax; `kro/*.yaml` paths that don't exist.
- `docs/platform-mvp/99-extending-to-eu-asia.md:23-32` — references `make deploy-spoke REGION=eu` and `kind-eu.yaml` which don't exist.
- Tracked binary `platform-mvp/dex-auth-plugin/dex-auth-plugin`.
- Unresolved: Dex `infrastructureClients` kept vs design doc says remove (`oidc-trust-v2.md:195`).

## 8. Sources

- openmcp: https://github.com/openmcp-project · https://open-control-plane.io · ADR kcp-aware runtime (2026-08-20) · `service-provider-kro`, `multicluster-provider`
- Platform Mesh: https://github.com/platform-mesh/platform-mesh · https://github.com/platform-mesh/architecture (ADR 002, RFC 001/006/010) · `helm-charts` 0.5.2
- ORD: https://open-resource-discovery.github.io/specification (1.16) · `provider-server`, `specification` JSON schema
- OpenKCM: https://github.com/openkcm · ADR-101/102/103/501 in `openkcm/documentation` · ROADMAP.md (Platform Mesh integration Q4 2026)
- NeoNephos: https://neonephos.org/projects · https://github.com/neonephos/projects (lifecycle policy v2) · https://apeirora.eu/content/projects/
