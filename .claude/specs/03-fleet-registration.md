# 03-fleet-registration Spec
# RED phase

## Goal
Hub knows about `us` as a named cluster via multicluster-runtime Provider interface.

## Acceptance Criteria
1. Provider interface compiles and tests pass
2. Manager interface compiles and tests pass
3. cluster-inventory-api provider compiles and tests pass
4. `ClusterProfile` CRD installed and profile applied on hub
5. Provider.Get(ctx, "us") returns a working Cluster