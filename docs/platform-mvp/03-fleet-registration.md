# Phase 3 — Fleet Registration

Registering the `us` spoke cluster on the hub via `ClusterProfile` CRD and the `cluster-inventory-api` multicluster provider.

---

## How It Works

```mermaid
sequenceDiagram
    participant Admin as Operator
    participant Hub as Hub API
    participant CP as ClusterProfile/us
    participant P as cluster-inventory-api Provider
    participant MGR as multicluster.Manager
    participant Secret as us-kubeconfig Secret

    Admin->>Hub: kubectl create secret generic us-kubeconfig<br/>--from-file=kubeconfig=./us-internal.kubeconfig
    Admin->>Hub: kubectl apply -f ClusterProfile/us

    loop every 10s (provider poll)
        P->>Hub: List ClusterProfiles
        Hub-->>P: [{name: us, ...}]

        P->>Hub: Get Secret us-kubeconfig
        Hub-->>P: {kubeconfig bytes}

        P->>P: clusterKey(Host, CAData)
        alt first time or host/CA changed
            P->>P: parse REST config from kubeconfig
            P->>MGR: Engage(ctx, "us", cluster)
            MGR->>MGR: start informers, caches
            MGR-->>P: engaged
        else key unchanged
            P->>P: skip (no-op)
        end
    end
```

## Provider Implementation

The provider at `providers/cluster-inventory-api/provider.go` implements `sigs.k8s.io/multicluster-runtime`'s `Provider` interface:

```go
type Provider interface {
    Get(ctx context.Context, clusterName string) (cluster.Cluster, error)
    IndexField(ctx context.Context, obj client.Object, field string, extractValue client.IndexerFunc) error
}
```

Plus the convention-based `Run(ctx, mgr)` method for cluster discovery.

### Poll Loop (`provider.go:120-222`)

1. **Discover** — `hubClient.List(ctx, &clusterProfiles)` at configured interval (default 10s)
2. **Locate kubeconfig** — Look up `<name>-kubeconfig` Secret in same namespace as ClusterProfile
3. **Change detection** — Compute clusterKey from server URL + CA certificate data; skip if unchanged (v2: token changes are irrelevant — tokens come from BearerTokenFile, not kubeconfig)
4. **Disengage old** — If clusterKey changed (server URL or CA), cancel old cluster's context
5. **Build cluster** — Parse kubeconfig → `cluster.New(restConfig, scheme)`, override auth with `BearerTokenFile`
6. **Engage** — `mgr.Engage(ctx, name, cl)` registers the spoke
7. **Replay indexes** — Replay any registered `IndexField` calls against the new cluster
8. **Cleanup** — Remove clusters whose ClusterProfile has been deleted

### Change Detection (v2: clusterKey)

In v2, the provider uses a clusterKey (SHA256 of `Host + CAData`) instead of the full kubeconfig hash. This means:

- **Server URL change** → disengage + re-engage with new credentials
- **CA certificate change** → disengage + re-engage
- **Token change** → **no-op** (tokens come from `BearerTokenFile`, Kubelet-managed)

This decouples credential rotation from cluster engagement, eliminating the tight coupling between the token-rotator and the multicluster provider.

## ClusterProfile CRD

Defined in `deploy/platform-mvp/chart/hub-services/templates/fleet.yaml`:

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ClusterProfile
metadata:
  name: us
```

The `status` subresource includes:

| Field | Purpose |
|-------|---------|
| `conditions[type=ControlPlaneHealthy]` | v1: Gated by token-rotator; v2: no longer required (auth via BearerTokenFile + Kubelet) |
| `accessProviders[*].cluster` | Contains `server` URL and `certificateAuthorityData` for kubeconfig assembly |

In production, a control plane health controller would populate `ControlPlaneHealthy` based on actual spoke API reachability. For E2E testing, this is patched manually.

## Acceptance

- `ClusterProfile us` visible on hub
- Provider discovers and engages the spoke
- `multicluster.Manager.GetCluster(ctx, "us")` returns a working cluster client
- `04-fleet-registration` Chainsaw test passes

## Key Files

| File | Purpose |
|------|---------|
| `providers/cluster-inventory-api/provider.go` | Provider: poll loop, engagement, clusterKey change detection (Host+CAData) |
| `deploy/platform-mvp/chart/hub-services/templates/fleet.yaml` | ClusterProfile/us manifest |
| `platform-mvp/binding-controller/main.go:123-176` | `staticProvider` — dev fallback (single cluster via kubeconfig flag) |