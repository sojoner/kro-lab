# Platform MVP: Kro + multicluster-runtime + Rook-Ceph

A guided, test-driven walkthrough proving a multi-cluster platform architecture using
[Kro](https://github.com/kubernetes-sigs/kro) (ResourceGraphDefinition),
[multicluster-runtime](https://github.com/kubernetes-sigs/multicluster-runtime),
[Rook/Ceph](https://github.com/rook/rook) (RGW S3), and
[Chainsaw](https://github.com/kyverno/chainsaw) for declarative E2E validation —
all running locally on `kind`.

**Concept**: A platform team defines a `GlobalBucket` API via Kro on a hub cluster.
A binding controller (multicluster-runtime) fans expanded intents out to a spoke
cluster running Rook/Ceph with an S3 gateway. No cloud dependency.

## Architecture

```
 hub (kind-hub)                            us (kind-us)
 ┌──────────────────────┐                 ┌──────────────────────┐
 │ Kro RGD              │                 │ Rook/Ceph            │
 │ GlobalBucket ──┐     │                 │  CephCluster         │
 │                │     │ binding-ctrl    │  CephObjectStore     │
 │ RegionalBucket-┼─────┼────────────────▶│  CephObjectStoreUser │
 │ Request (RBR)       │ watches hub,    │  ObjectBucketClaim   │
 │                │     │ creates on us   │  RGW S3 endpoint     │
 ├──────────────────────┤                 └──────────────────────┘
 │ Observability        │
 │  grafana             │                  host (bm4080.taildf7067.ts.net)
 │  prometheus          │                  ┌──────────────────────┐
 │  loki                │                  │ Tailscale            │
 │  event-exporter      │                  │  :30080 → hub:80     │
 │  ingress-nginx       │                  │  :30443 → hub:443    │
 │ chainsaw CronJob     │                  │ grafana at /         │
 └──────────────────────┘                  └──────────────────────┘
```

| Cluster | Nodes | Purpose |
|---------|-------|---------|
| `kind-hub` | 1 control-plane | Hub: Kro API, observability, Flux CD, ingress |
| `kind-us` | 1 ctrl-plane + 1 worker | Spoke: Rook/Ceph, RGW S3 |

## Prerequisites

| Tool | Min Version | Check |
|------|-------------|-------|
| [Go](https://go.dev/dl/) | 1.23+ | `go version` |
| [Docker](https://docs.docker.com/engine/install/) | 24+ | `docker version` |
| [kind](https://kind.sigs.k8s.io/#installation) | 0.26+ | `kind version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.30+ | `kubectl version --client` |
| [Chainsaw](https://kyverno.github.io/chainsaw/latest/quick-start/) | latest | `chainsaw version` |
| [Helm](https://helm.sh/docs/intro/install/) | 3.16+ | `helm version` |
| [Flux CLI](https://fluxcd.io/flux/installation/) | 2.4+ | `flux --version` |
| [kind](https://kind.sigs.k8s.io/#installation) | 0.26+ | `kind version` |

Install:
```bash
go install github.com/kyverno/chainsaw@latest
make install-flux
```

## Quick Start

```bash
make all        # Full loop: lint → test → build → deploy → validate
make grafana    # Port-forward Grafana → http://localhost:3000 (admin/admin)
make clean      # Destroy everything
```

### Step by Step

```bash
make lint       # go vet + gofmt check
make test       # unit tests (root + binding-controller)
make build      # build binding-controller binary → bin/
make deploy     # create clusters + deploy us (Rook) + hub (LGTM + Kro + Flux)
make validate   # run all Chainsaw E2E test suites at once
make clean      # destroy everything
```

### Dashboard Link

After deployment:

```bash
make grafana-url
```

| Dashboard | URL |
|-----------|-----|
| Cluster Fitness | `http://bm4080.taildf7067.ts.net/d/cluster-fitness` |
| Chainsaw Test Results | `http://bm4080.taildf7067.ts.net/d/chainsaw-results` |
| Controller + Rook Recon | `http://bm4080.taildf7067.ts.net/d/controller-rook-recon` |
| Controller Deep Dive | `http://bm4080.taildf7067.ts.net/d/controller-deep-dive` |

Login: `admin` / `admin`

## Guided Validation — Chainsaw Test Suites

Each test validates one layer of the platform. Run them as a group:

### Core Platform (tests 1-6)

```bash
make validate-p1-p6
```

| Test | What It Proves |
|------|----------------|
| 01-hub-cluster-ready | Hub cluster has 1 node Ready |
| 02-us-cluster-ready | Us spoke has 2 nodes (1 ctrl-plane + 1 worker) |
| 03-rook-ceph-healthy | Rook operator deployed, Ceph reports HEALTH_OK/HEALTH_WARN |
| 04-fleet-registration | ClusterProfile `us` registered on hub via multicluster API |
| 05-kro-globalbucket | Kro RGD expands GlobalBucket → RegionalBucketRequest per region |
| 06-binding-controller | Controller creates CephObjectStoreUser + ObjectBucketClaim on us |

**What this proves**: A platform team defined a `GlobalBucket` on the hub cluster.
Kro expanded it to `RegionalBucketRequest` per region. The binding controller
watched and provisioned real S3 bucket credentials on the Rook/Ceph spoke.

### Observability Stack (tests 7-9)

```bash
make validate-p7-p9
```

| Test | What It Proves |
|------|----------------|
| 07-observability-stack | Prometheus, Grafana, Loki running; ServiceMonitors exist |
| 08-chainsaw-cronjob | Chainsaw CronJob deployed in cluster |
| 09-ingress-log-shipping | Ingress controller routes to Grafana, Loki accepts pushes |

**What this proves**: LGTM stack deployed via umbrella Helm chart. Grafana
reachable through nginx ingress. Metrics and logs aggregated.

## Development Workflow (TDD)

```
🔴 RED → 🟢 GREEN → 🔄 REFACTOR
```

```bash
# Before every change:
make tdd-lint     # verify clean baseline

# RED: Write a failing test
make test         # must FAIL

# GREEN: Write minimal code to pass
make test         # must PASS

# REFACTOR: Improve code, keep tests passing
make tdd-lint     # lint check
make test         # must still PASS
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Full loop: lint → test → build → deploy → validate |
| `make test` | Run all unit tests |
| `make test-race` | Unit tests with race detector |
| `make test-cover` | Unit tests with coverage profiles |
| `make lint` | go vet + gofmt check |
| `make lint-fix` | Auto-fix formatting + go vet |
| `make tdd-lint` | Pre-change lint baseline |
| `make build` | Build binding-controller binary |
| `make deploy` | Full deployment (clusters + us + hub) |
| `make deploy-us` | Install Rook/Ceph on us |
| `make deploy-hub` | Install LGTM stack + Kro + Flux on hub |
| `make validate` | Run all Chainsaw E2E tests (1-9) |
| `make validate-p1-p6` | Core platform tests (cluster, rook, fleet, kro, binding) |
| `make validate-p7-p9` | Observability tests (stack, cronjob, ingress) |
| `make grafana` | Port-forward Grafana → localhost:3000 |
| `make grafana-url` | Print dashboard URLs |
| `make clean` | Destroy clusters and artifacts |
| `make clean-artifacts` | Remove bin/ and coverage files only |

## Project Structure

```
.
├── deploy/platform-mvp/
│   ├── chart/hub/                 # Umbrella Helm chart (LGTM + ingress + kro)
│   │   ├── templates/             #   dashboards, event-exporter, servicemonitors,
│   │   │                         #   fleet, chainsaw, kro-rgd, grafana-ingress
│   │   ├── dashboards/            #   4 Grafana dashboard JSONs
│   │   ├── Chart.yaml             #   Dependencies: kube-prometheus-stack, loki,
│   │   └── values.yaml            #                  promtail, ingress-nginx
│   ├── chart/us/                  # Umbrella Helm chart (Rook operator + cluster)
│   │   ├── Chart.yaml             #   Dependencies: rook-ceph, rook-ceph-cluster
│   │   └── values.yaml
│   ├── flux/                      # Flux CD manifests
│   │   ├── bootstrap/             #   One-time bootstrap (GitRepository, Kustomization)
│   │   ├── helmrepositories.yaml  #   4 HelmRepository sources
│   │   └── hub-helmrelease.yaml   #   HelmRelease for hub chart
│   ├── kind/                      # kind cluster configs
│   ├── rook/                      # Original Rook values (for reference)
│   ├── fleet/                     # Original ClusterProfile (for reference)
│   ├── kro/                       # RGD, RBAC, CRD manifests
│   └── observability/             # Original LGTM values + Dockerfile.chainsaw-runner
├── hack/platform-mvp/             # Shell scripts (called by Makefile)
├── platform-mvp/
│   └── binding-controller/        # RegionalBucket → spoke reconciler (Go)
│       └── controller/            #   Reconciler + tests
├── providers/
│   └── cluster-inventory-api/     # ClusterProfile-backed Provider (Go)
├── tests/e2e/                     # Chainsaw test suites
│   ├── tests/                     #   01..09 progressive validation
│   └── .chainsaw.yaml
├── docs/platform-mvp/             # Implementation docs per phase
├── .claude/                       # AI assistant working docs (plans/specs)
├── Makefile                       # Build, deploy, validate automation
└── README.md                      # This file
```

## Cleanup

```bash
make clean            # destroy clusters, remove artifacts
make clean-artifacts  # remove bin/ and coverage files only
```

---

## License

© 2026 sojoner