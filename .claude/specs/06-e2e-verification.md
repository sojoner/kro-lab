# 06-e2e-verification Spec
# Chainsaw-based cloud-native validation

## Goal
Prove full platform MVP loop using Chainsaw declarative tests.

## Acceptance Criteria
1. 01-hub-cluster-ready — hub has 1 node
2. 02-us-cluster-ready — us has 2 nodes
3. 03-widget-operator-healthy — Widget CRD installed, operator Deployment Ready
4. 04-fleet-registration — ClusterProfile us exists
5. 05-kro-globalwidget — RegionalWidgetRequest created
6. 06-binding-controller — Widget created on spoke, status.phase reaches Ready with endpoint populated
7. All Chainsaw tests pass from `tests/e2e/`
