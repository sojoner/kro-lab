# 06 — E2E verification (Chainsaw)

## Goal
Prove the full loop using Chainsaw declarative tests.

## Test structure

```
tests/e2e/
├── .chainsaw.yaml                     # Multi-cluster config (hub + us)
├── tests/
│   ├── 01-hub-cluster-ready.yaml      # Assert hub has 1 node
│   ├── 02-us-cluster-ready.yaml       # Assert us has 2 nodes
│   ├── 04-fleet-registration.yaml     # Assert ClusterProfile registered
│   ├── 05-kro-globalwidget.yaml       # Assert GlobalWidget -> RegionalWidgetRequest
│   └── 06-binding-controller.yaml     # Assert Widget on spoke
```

## Run

```bash
# Full E2E (creates clusters, installs everything, runs Chainsaw)
make validate

# Or run Chainsaw directly (clusters must already exist)
chainsaw test tests/e2e/
```

## Acceptance
- All 5 Chainsaw tests pass