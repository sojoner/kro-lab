# 01-kind-topology Spec
# RED phase — define what must be true before implementation starts

## Goal
Two reachable kind clusters: `hub` and `us`, connected via shared Docker network.

## Acceptance Criteria
1. `kubectl --context kind-hub get nodes` succeeds
2. `kubectl --context kind-us get nodes` succeeds (1 control-plane + 3 workers)
3. `docker exec kind-us-control-plane ping -c1 <hub-apiserver-ip>` succeeds
4. `kind get kubeconfig --name us --internal` returns kubeconfig with in-Docker-network address