# Chainsaw E2E Test Suite — Polis Platform

## Summary

| # | Test | Covers | Clusters |
|---|------|--------|----------|
| 01 | Hub cluster ready | Nodes exist, API accessible | hub |
| 02 | US spoke cluster ready | Nodes exist | US |
| 03 | Widget operator healthy | Pod running, metrics endpoint | US |
| 04 | Fleet registration | ClusterProfile secrets created | hub |
| 05 | Kro GlobalWidget RGD | GlobalWidget → RegionalWidgetRequest | hub |
| 06 | Binding controller | RWR → Widget on spoke | hub, US |
| 07 | Observability stack | LGTM pods healthy | hub |
| 08 | Chainsaw CronJob | Self-testing runner | hub |
| 09 | Ingress log shipping | Loki receives k8s events | hub |
| 10 | OIDC trust | Dex + OIDC verifier auth chain | hub, US |
| 11 | Rotating trust | Kubelet token rotation integrity | hub, US |
| 12 | Dashboard metrics | Grafana dashboards populated | hub |
| 13 | Tenant isolation | Namespace-scoped resources | hub, US |
| **14** | **Product catalog ORD** | **Catalog controller serves valid ORD doc** | **hub** |
| 15 | Dashboard data | Chainsaw results in Loki | hub |
| 16 | Auth configuration | AuthenticationConfiguration active | US |
| 17 | Projected SA tokens | Kubelet token projection | hub, US |
| 18 | Admission guardrails | VAP deny-by-default rules | US |
| 19 | Multi-tenant isolation | Cross-tenant access denied | hub, US |
| 20 | Tenant RBAC roles | RoleBindings correctly scoped | US |
| 21 | Platform admin access | Admin RBAC works | hub, US |
| **22** | **Offer + Binding contracts** | **Offer/Binding CRDs, Binding→Accepted** | **hub** |

**Bold** = new Polis Phase 13–20 tests.

## New Test Details

### Test 14 — Product Catalog (ORD validation)
- **Assert:** Product CRD installed on hub
- **Assert:** Widget Product instance exists
- **Poll:** catalog-controller pod, GET `/.well-known/open-resource-discovery` via `kubectl exec`
- **Validate:** ORD response contains `acme-corp` vendor, `Widget` product, non-empty `packages[]` and `apiResources[]`
- **Timeout:** 90s total (15 × 2s polling)

### Test 22 — Offer/Binding Contracts
- **Assert:** Offer CRD installed
- **Assert:** Binding CRD installed
- **Apply:** Test Offer with `productRef: widget`, `allowTenants: ["*"]`, credential template
- **Apply:** Test Binding referencing the Offer, `version: v1alpha1`, accepted claims
- **Poll:** Binding `status.phase` → `Accepted`/`Active` within 60s
- **Cleanup:** `finally` blocks delete test Offer and Binding

## Contracts Covered by Spec

| Phase | CRDs Validated | Controller Validated | Cross-Cluster |
|-------|---------------|---------------------|---------------|
| 14 | Product | catalog-controller ORD output | No |
| 15 (22) | Offer, Binding | contract-controller phase=Accepted | No |
| 16 | (covered by 15/22) | Binding→Seal trigger | No |
| 17 | Seal | seal-controller secret creation | No |
| 18 | Citizen | citizen-controller oidcSub validation | No |
| 19 | Deme | deme-controller namespace creation | No |
| 20 | Colony | colony-controller region registration | No |

Note: Phases 17–20 have controllers written and compile/vec clean but lacking dedicated Chainsaw tests — these should be added as the platform integrades with real OpenBao/OpenKCM/openmcp dependencies.

## Running

```bash
# Full suite (all 22 tests)
make validate

# Specific test
chainsaw test tests/e2e/tests/14-product-catalog/ --config tests/e2e/.chainsaw.yaml

# With custom kubeconfigs
export KUBECONFIG_HUB=./kubeconfig-hub
export KUBECONFIG_US=./kubeconfig-us-internal
```