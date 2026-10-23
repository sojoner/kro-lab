# Phase 20 — Colonies: Multi-Region ORD Aggregation

## What a Colony Is

A Colony represents a **spoke region** and its ORD (Open Resource Discovery) aggregation view. It is a cluster-scoped CRD (`colonies.agora.platform.example.com`) that combines the region's Product instances with their runtime status.

Each Colony provides the hub with:
- The identity of the spoke region (us, eu, asia)
- A reference to the spoke's ClusterProfile (for multicluster connectivity)
- An optional ORD well-known URL (the spoke's catalog endpoint)
- A provider configuration (auth type and credential secret)

| Field | Purpose |
|-------|---------|
| `spec.region` | Region identifier: us, eu, or asia |
| `spec.clusterProfileRef.name` | Name of the ClusterProfile for this spoke |
| `spec.ordWellKnownURL` | The spoke's ORD catalog endpoint (optional) |
| `spec.providerConfig.auth` | Authentication method: Token or X509 |
| `spec.providerConfig.secretRef.name` | Secret containing spoke credentials |

## How Multi-Region ORD Aggregation Works

The Polis implements a **global catalog** by aggregating ORD documents from each spoke region:

```
Hub Catalog (hub-side Products + Offers)
   +
Spoke Catalog/us (ORD well-known endpoint)
Spoke Catalog/eu
Spoke Catalog/asia
   =
Global Catalog (aggregated ORD view)
```

1. **Hub-side catalog**: The hub itself hosts Products, Offers, and Bindings — these are the platform-level catalog entries managed by the `catalog-controller`.

2. **Spoke-side catalogs**: Each spoke cluster may expose an ORD `.well-known` endpoint that describes its local Product instances. The Colony's `ordWellKnownURL` field points to this endpoint.

3. **Aggregation**: The Polis fetches ORD documents from each Colony's well-known URL and merges them into a single global catalog view, available to all tenants.

## Colony Lifecycle

| Phase | Meaning |
|-------|---------|
| **Pending** | Colony created; not yet connected to the spoke |
| **Joined** | Spoke has been engaged via the multicluster provider |
| **Healthy** | Spoke is responsive; products are running |
| **Degraded** | Spoke is reachable but products are failing |
| **Left** | Colony has been disconnected; spoke is no longer engaged |

The model mirrors the ClusterProfile lifecycle (Pending → Ready → Left) but adds explicit Healthy/Degraded states for runtime product health monitoring.

## Future: openmcp Cluster Integration

The Colony concept is designed to integrate with **openmcp** (Open Multi-Cluster Platform) as a future enhancement:

- A Colony could be backed by an openmcp `Cluster` resource instead of a `ClusterProfile`
- The `providerConfig.auth` field already supports Token and X509 modes, matching openmcp's auth options
- `ordWellKnownURL` would be resolved from openmcp's cluster metadata
- The phase transitions (Pending → Joined → Healthy/Degraded → Left) align with openmcp's cluster lifecycle states

This keeps the Colony abstraction consistent whether the underlying multi-cluster mechanism is ClusterProfile/fleet or openmcp.

## CRD and Hub Instance

| Artifact | Location |
|----------|----------|
| Colony CRD | `deploy/platform-mvp/chart/crds/templates/colony-crd.yaml` |
| US Colony instance | `deploy/platform-mvp/chart/hub-services/templates/us-colony.yaml` |

## Key Files

| File | Purpose |
|------|---------|
| `deploy/platform-mvp/chart/crds/templates/colony-crd.yaml` | Colony CRD schema |
| `deploy/platform-mvp/chart/hub-services/templates/us-colony.yaml` | US region Colony (references ClusterProfile/us) |

## Acceptance

- Colony CRD is installed on the hub
- `kubectl get colonies.agora.platform.example.com` shows printer columns (Region, Phase, Products, Heartbeat)
- `us-colony.yaml` is deployable as a hub-service instance
- The Colony spec matches the ClusterProfile naming (`clusterProfileRef.name: us` ↔ `ClusterProfile/us`)
