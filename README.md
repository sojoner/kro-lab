# Platform MVP: Kro + multicluster-runtime on kind

A guided, test-driven walkthrough proving a multi-cluster platform architecture using
[Kro](https://github.com/kubernetes-sigs/kro) (ResourceGraphDefinition),
[multicluster-runtime](https://github.com/kubernetes-sigs/multicluster-runtime), and
[Chainsaw](https://github.com/kyverno/chainsaw) for declarative E2E validation —
all running locally on `kind`.

**Concept**: A platform team defines a `GlobalWidget` API via Kro on a hub cluster.
A binding controller (multicluster-runtime) fans expanded intents out to a spoke
cluster running a trivial widget-operator. No cloud dependency.

## Architecture

```
 hub (kind-hub)                            us (kind-us)
 ┌──────────────────────┐                 ┌──────────────────────┐
 │ Kro RGD              │                 │ widget-operator      │
 │ GlobalWidget ──┐     │                 │  Widget CRD          │
 │                │     │ binding-ctrl    │                      │
 │ RegionalWidget─┼─────┼────────────────▶│  Widget instances    │
 │ Request (RWR)       │ watches hub,    │                      │
 │                │     │ creates on us   │ oidc-verifier        │
 ├──────────────────────┤                 │  /verify (JWKS-based)│
 │ Observability        │                 │  AUDIT → stdout      │
 │  grafana             │                 └──────────────────────┘
 │  prometheus          │
 │  loki                │                  host (bm4080.taildf7067.ts.net)
 │  event-exporter      │                  ┌──────────────────────┐
 │  ingress-nginx       │                  │ Tailscale            │
 │ Dex IDP (OIDC)       │                  │  :30080 → hub:80     │
 │ cert-manager (TLS)   │                  │  :30443 → hub:443    │
 │ chainsaw CronJob     │                  │ grafana at /         │
 └──────────────────────┘                  │ dex at /dex          │
                                           └──────────────────────┘
```

| Cluster | Nodes | Purpose |
|---------|-------|---------|
| `kind-hub` | 1 control-plane | Hub: Kro API, observability, Dex OIDC, cert-manager, Flux CD, ingress |
| `kind-us` | 1 ctrl-plane + 1 worker | Spoke: widget-operator, oidc-verifier |

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
make test       # unit tests (root + binding-controller + widget-operator)
make build      # build binding-controller binary → bin/
make deploy     # create clusters + deploy us (widget-operator) + hub (LGTM + Kro + Flux)
make validate   # run all Chainsaw E2E test suites at once
make clean      # destroy everything
```

### Dashboard Links

After deployment, access Grafana at `http://bm4080.taildf7067.ts.net` (login: `admin` / `admin`):

| Dashboard | URL | What It Shows |
|-----------|-----|---------------|
| Cluster Fitness | [`/d/cluster-fitness`](http://bm4080.taildf7067.ts.net/d/cluster-fitness) | Node readiness, CPU%, memory, API server health across both clusters |
| Chainsaw Test Results | [`/d/chainsaw-results`](http://bm4080.taildf7067.ts.net/d/chainsaw-results) | E2E test pass/fail, duration trends, pass rate over time |
| Controller Deep Dive | [`/d/controller-deep-dive`](http://bm4080.taildf7067.ts.net/d/controller-deep-dive) | Reconcile throughput, latency, per-tenant breakdown, spoke API latency |
| Token Rotation | [`/d/token-rotation`](http://bm4080.taildf7067.ts.net/d/token-rotation) | Token rotation rate per region, last rotation age, error rate, debug logs |

```bash
make grafana-url   # print all dashboard URLs
make grafana       # port-forward Grafana → http://localhost:3000 (admin/admin)
```

## Guided Validation — Chainsaw Test Suites

Each test validates one layer of the platform.

### Core Platform (tests 1-6)

```bash
make validate-p1-p6
```

| Test | What It Proves |
|------|----------------|
| 01-hub-cluster-ready | Hub cluster has 1 node Ready |
| 02-us-cluster-ready | Us spoke has 2 nodes (1 ctrl-plane + 1 worker) |
| 04-fleet-registration | ClusterProfile `us` registered on hub via multicluster API |
| 05-kro-globalwidget | Kro RGD expands GlobalWidget → RegionalWidgetRequest per region |
| 06-binding-controller | Controller creates Widget on us spoke |

**What this proves**: A platform team defined a `GlobalWidget` on the hub cluster.
Kro expanded it to `RegionalWidgetRequest` per region. The binding controller
watched and provisioned Widget instances on the spoke cluster.

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

### OIDC Trust (test 10)

```bash
chainsaw test tests/e2e --test 10-oidc-trust
```

| Test | What It Proves |
|------|----------------|
| 10-oidc-trust | Dex issues JWT, oidc-verifier on spoke validates, audit logs in Loki |

**What this proves**: Workload identity (client_credentials) flows from hub Dex
IDP to spoke oidc-verifier. Cross-cluster JWKS-based trust. Full audit trail
from JWT verification → stdout → promtail → Loki → Grafana.

### Rotating Trust & Observability (tests 11-12)

```bash
chainsaw test tests/e2e --test 11-rotating-trust
chainsaw test tests/e2e --test 12-dashboard-metrics
```

| Test | What It Proves |
|------|----------------|
| 11-rotating-trust | Token rotator renews Dex tokens per region; kubeconfig Secrets updated |
| 12-dashboard-metrics | All 4 Grafana dashboards loaded; custom Prometheus metrics for token rotation and multi-tenancy scraped and visible |

**What this proves**: Token rotation keeps spoke access fresh without manual
intervention. Custom metrics (`token_rotator_*`, `binding_controller_reconcile_total`)
are served by the application, scraped by Prometheus, and visible in Grafana
dashboards — proving multi-tenancy and token rotation in real time.

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
| `make test` | Run all unit tests (includes oidc-verifier) |
| `make test-race` | Unit tests with race detector |
| `make test-cover` | Unit tests with coverage profiles |
| `make lint` | go vet + gofmt check (incl. oidc-verifier) |
| `make lint-fix` | Auto-fix formatting + go vet |
| `make tdd-lint` | Pre-change lint baseline |
| `make build` | Build binding-controller binary |
| `make oidc-verifier-image` | Build + load oidc-verifier Docker image |
| `make deploy` | Full deployment (clusters + us + hub) |
| `make deploy-us` | Install widget-operator + oidc-verifier on us |
| `make deploy-hub` | Install LGTM + Dex + cert-manager + Kro + Flux on hub |
| `make validate` | Run all Chainsaw E2E tests (1-12) |
| `make validate-p1-p6` | Core platform tests (cluster, fleet, kro, binding) |
| `make validate-p7-p9` | Observability tests (stack, cronjob, ingress) |
| `make grafana` | Port-forward Grafana → localhost:3000 |
| `make grafana-url` | Print dashboard URLs |
| `make clean` | Destroy clusters and artifacts |
| `make clean-artifacts` | Remove bin/ and coverage files only |

## Project Structure

```
.
├── deploy/platform-mvp/
│   ├── chart/hub/                 # Umbrella Helm chart (LGTM + ingress + Dex + cert-manager)
│   │   ├── templates/             #   dashboards, event-exporter, servicemonitors,
│   │   │                         #   fleet, chainsaw, kro-rgd, grafana-ingress,
│   │   │                         #   dex, dex-ingress, cert-manager, binding-controller
│   │   ├── dashboards/            #   4 Grafana dashboard JSONs
│   │   ├── Chart.yaml             #   Dependencies: kube-prometheus-stack, loki, promtail,
│   │   └── values.yaml            #                  ingress-nginx, cert-manager
│   ├── chart/us/                  # Helm chart (widget-operator + oidc-verifier)
│   │   ├── templates/widget-operator.yaml
│   │   ├── templates/oidc-verifier.yaml
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── flux/                      # Flux CD manifests
│   │   ├── bootstrap/             #   One-time bootstrap (GitRepository, Kustomization)
│   │   ├── helmrepositories.yaml  #   3 HelmRepository sources
│   │   └── hub-helmrelease.yaml   #   HelmRelease for hub chart
│   ├── kind/                      # kind cluster configs
│   ├── fleet/                     # Original ClusterProfile (for reference)
│   ├── kro/                       # RGD, RBAC, CRD manifests
│   └── observability/             # Original LGTM values + Dockerfile.chainsaw-runner
├── hack/platform-mvp/             # Shell scripts
├── platform-mvp/
│   ├── binding-controller/        # RegionalWidgetRequest → spoke reconciler (Go)
│   │   └── controller/            #   Reconciler + tests
│   ├── widget-operator/           # Trivial spoke operator (Go)
│   └── oidc-verifier/             # JWKS-based JWT verifier (Go)
├── providers/
│   └── cluster-inventory-api/     # ClusterProfile-backed Provider (Go)
├── tests/e2e/                     # Chainsaw test suites
│   ├── tests/                     #   01..12 progressive validation
│   └── .chainsaw.yaml
├── docs/platform-mvp/             # Implementation docs per phase (incl. OIDC)
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