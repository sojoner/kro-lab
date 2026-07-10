# 99 — Extending to EU/ASIA (design-only)

This document describes the extension path without implementing it.

## What's already handled

The architecture is designed for multi-region from day one:

- **Kro RGD**: `spec.regions` is `[]string` — adding `eu` or `asia` requires zero RGD changes
- **Binding controller**: uses `mgr.GetCluster(ctx, ClusterName(region))` generically — any registered ClusterProfile is automatically discovered
- **RegionalWidgetRequest**: schema supports arbitrary region names

## What's needed per new region

Repeat these steps for each new region (e.g., `eu`):

### Phase 1 — New kind cluster
```bash
kind create cluster --name eu --config deploy/platform-mvp/kind/kind-eu.yaml
kind get kubeconfig --name eu --internal > hack/platform-mvp/kubeconfig-eu-internal
```

### Phase 2 — Widget operator in new cluster
```bash
# Deploy widget-operator on eu
```

### Phase 3 — New ClusterProfile
```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterProfile
metadata:
  name: eu
spec:
  kubeconfigSecretRef:
    name: eu-kubeconfig
```

### Phase 4-5 — No changes needed
Kro RGD and binding controller already handle arbitrary regions.