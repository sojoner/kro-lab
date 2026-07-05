# 03 — Fleet registration

## Goal
Hub knows about `us` as a named cluster via `ClusterProfile` CRD.

## Prerequisites
- Phase 1-2 complete
- `cluster-inventory-api` ClusterProfile CRD installed on hub

## Steps

```bash
# Install ClusterProfile CRD on hub
kubectl --context kind-hub apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-inventory-api/main/config/crd/bases/multicluster.x-k8s.io_clusterprofiles.yaml

# Create kubeconfig secret from us internal kubeconfig
kubectl --context kind-hub create secret generic us-kubeconfig \
    --from-file=value=hack/platform-mvp/kubeconfig-us-internal

# Apply ClusterProfile
kubectl --context kind-hub apply -f deploy/platform-mvp/fleet/clusterprofile-us.yaml
```

## Files produced
- `deploy/platform-mvp/fleet/clusterprofile-us.yaml`
- `hack/platform-mvp/register-fleet.sh`

## Go implementation
- `providers/cluster-inventory-api/provider.go` — implements the real `sigs.k8s.io/multicluster-runtime` `multicluster.Provider` interface (`Get`, `IndexField`), plus a `Run(ctx, mcmanager.Manager)` loop that polls `ClusterProfile` objects on hub and `mgr.Engage(...)`s a real `cluster.Cluster` for each one discovered — this dynamic engagement is what lets cross-cluster controllers (built via `mcbuilder`) attach watches to spoke clusters. `ClusterProfileGVK` is `multicluster.x-k8s.io/v1alpha1` — must match the installed CRD's actual group/version, verified by `TestProviderGet_ClusterProfileAPIGroup`.

## Acceptance
- `kubectl --context kind-hub get clusterprofile us` returns the profile
- Provider `Get(ctx, "us")` returns a working `cluster.Cluster` with client
- Provider `Run` engages the manager with `us` once its `ClusterProfile` is discovered
- `chainsaw test tests/e2e --test 04-fleet-registration` passes