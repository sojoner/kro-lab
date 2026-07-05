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
 hub (kind-hub)                          us (kind-us)
 ┌──────────────┐                       ┌──────────────────────┐
 │ Kro RGD      │                       │ Rook/Ceph            │
 │ GlobalBucket ─┐                      │  CephCluster         │
 │              │ │  binding-controller  │  CephObjectStore     │
 │ RegionalBuck─┼─┼────────────────────▶│  CephObjectStoreUser │
 │ etRequest    │    watches hub,       │  ObjectBucketClaim   │
 │              │    creates on spoke   │  RGW S3 endpoint     │
 └──────────────┘                       └──────────────────────┘
```

## Prerequisites

| Tool | Min Version | Check |
|------|-------------|-------|
| [Go](https://go.dev/dl/) | 1.23+ | `go version` |
| [Docker](https://docs.docker.com/engine/install/) | 24+ | `docker version` |
| [kind](https://kind.sigs.k8s.io/#installation) | 0.26+ | `kind version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.30+ | `kubectl version --client` |
| [Chainsaw](https://kyverno.github.io/chainsaw/latest/quick-start/) | latest | `chainsaw version` |
| [Helm](https://helm.sh/docs/intro/install/) | 3.16+ | `helm version` |

Install Chainsaw: `go install github.com/kyverno/chainsaw@latest`

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │  host (100.96.124.118)                                          │
 │  Tailscale: bm4080.taildf7067.ts.net                            │
 │                                                                 │
 │  ┌─────────────────────────┐    ┌─────────────────────────────┐ │
 │  │ hub (kind-hub)          │    │ us (kind-us)                │ │
 │  │                         │    │                             │ │
 │  │  ● nginx ingress :80   │    │  ● rook-ceph (RGW S3)       │ │
 │  │  ● grafana              │    │  ● CephObjectStoreUser       │ │
 │  │  ● prometheus           │    │  ● ObjectBucketClaim         │ │
 │  │  ● loki                 │    │                             │ │
 │  │  ● promtail → logs      │    │                             │ │
 │  │  ● event-exporter       │    │                             │ │
 │  │  ● chainsaw CronJob/2m  │    │                             │ │
 │  │  ● kro RGD (GlobalBucket)│   │                             │ │
 │  │  ● binding-controller ──┼────┼─ creates COSU + OBC ────────▶│
 │  │                         │    │                             │ │
 │  └─────────────────────────┘    └─────────────────────────────┘ │
 │         ▲ :80                                                      │
 │         │                                                         │
 │  http://bm4080.taildf7067.ts.net ───→ Grafana dashboards           │
 └──────────────────────────────────────────────────────────────────┘
```

## Dashboard Link

After deployment, access the 4 Grafana dashboards:

```
make grafana-url
```

| Dashboard | URL |
|-----------|-----|
| Cluster Fitness | `http://bm4080.taildf7067.ts.net/d/cluster-fitness` |
| Chainsaw Test Results | `http://bm4080.taildf7067.ts.net/d/chainsaw-results` |
| Controller + Rook Recon | `http://bm4080.taildf7067.ts.net/d/controller-rook-recon` |
| Controller Deep Dive | `http://bm4080.taildf7067.ts.net/d/controller-deep-dive` |

Login: `admin` / `admin`

## Quick Start

```bash
# Full loop: test → lint → build → deploy → validate
make all

# Or step by step:
make lint          # go vet + gofmt check
make test          # unit tests (root + binding-controller)
make build         # build binding-controller binary
make deploy        # phases 1-5: clusters, rook, fleet, kro, controller
make validate      # run Chainsaw E2E test suites
make clean         # destroy everything
```

## Guided Validation — Chainsaw Test Suites

Each Chainsaw test validates one phase of the platform. Run them progressively to
learn how each layer is built and verified.

### Test 1: Cluster Topology

**What it proves**: Two kind clusters (`hub`, `us`) are running and reachable.

```bash
make validate-p1
```

Under the hood (`tests/e2e/tests/01-hub-cluster-ready.yaml`):
- `hub` cluster has 1 control-plane node
- `us` cluster has 4 nodes (1 control-plane + 3 workers)
- Cross-cluster network reachability via Docker bridge

### Test 2: Rook/Ceph on Spoke

**What it proves**: Real Ceph cluster with RGW S3 gateway running on spoke.

```bash
make validate-p2
```

Under the hood (`tests/e2e/tests/02-us-cluster-ready.yaml`, `03-rook-ceph-healthy.yaml`):
- Loop devices attached to worker containers for OSD backing
- Rook operator deployed, `CephCluster` and `CephObjectStore` created
- Ceph reports `HEALTH_OK` or `HEALTH_WARN` (not error)
- RGW S3 service reachable in-cluster

### Test 3: Fleet Registration

**What it proves**: Hub cluster discovers spoke via `ClusterProfile` CRD.

```bash
make validate-p3
```

Under the hood (`tests/e2e/tests/04-fleet-registration.yaml`):
- `ClusterProfile` CRD installed on hub
- Kubeconfig Secret referencing spoke's internal address
- `cluster-inventory-api` provider resolves `clusterProfile/us` → working client

### Test 4: Kro GlobalBucket API

**What it proves**: Kro ResourceGraphDefinition expands `GlobalBucket` →
`RegionalBucketRequest` per region.

```bash
make validate-p4
```

Under the hood (`tests/e2e/tests/05-kro-globalbucket.yaml`):
- `ResourceGraphDefinition` `globalbucket` applied on hub
- Creating `GlobalBucket{spec: {regions: [us]}}` produces `RegionalBucketRequest
  {name: <name>-us}` deterministically via `forEach` template

### Test 5: Binding Controller

**What it proves**: End-to-end — controller reconciles `RegionalBucketRequest` on
hub, creates real Rook resources on spoke.

```bash
make validate-p5
```

Under the hood (`tests/e2e/tests/06-binding-controller.yaml`):
- `RegionalBucketReconciler` watches hub for `RegionalBucketRequest` CRs
- Creates `CephObjectStoreUser` + `ObjectBucketClaim` on spoke via
  multicluster-runtime provider
- Status propagated back: credentials, endpoint, bucket name

### Test 6: Observability Stack

**What it proves**: LGTM (Loki+Grafana+Prometheus) stack deployed on hub with
ServiceMonitors for controller + Rook metrics. Chainsaw CronJob runs tests
in-cluster and pushes results to Loki for dashboard visualization.

```bash
make validate-p7     # stack: prometheus, grafana, loki, servicemonitors
make validate-p8     # cronjob: runs chainsaw, pushes results to loki
```

Under the hood (`tests/e2e/tests/07-observability-stack.yaml`, `08-chainsaw-cronjob.yaml`, `09-ingress-log-shipping.yaml`):
- kube-prometheus-stack (Prometheus + Grafana + kube-state-metrics) on hub
- Loki single-binary for log aggregation
- Promtail DaemonSet ships container logs → Loki
- Event exporter pushes Kubernetes events → Loki
- nginx ingress controller + Grafana Ingress (`bm4080.taildf7067.ts.net`)
- ServiceMonitor for `binding-controller` (reconcile metrics)
- ServiceMonitor for `rook-ceph-mgr` (Ceph health metrics)
- Chainsaw CronJob runs every 2m inside hub, pushes JSON reports to Loki
- Four Grafana dashboards: Cluster Fitness, Chainsaw Results, Controller+Rook, Controller Deep Dive

View dashboards:
```bash
make grafana-url    # get dashboard links
```

### Test 7: Chainsaw CronJob Execution

**What it proves**: CronJob creates a job every 2m, which runs chainsaw inside the
cluster, test results pushed to Loki (queryable from Grafana).

```bash
make validate-p8
```

### Test 8: Ingress & Log Shipping

**What it proves**: Grafana reachable via nginx ingress on the Tailscale FQDN.
Promtail and event exporter ship logs + events to Loki for the Deep Dive dashboard.

```bash
make validate-p9
```

### Full Suite

```bash
make validate    # all 8 Chainsaw tests (phases 1-7)
```

## Development Workflow (TDD)

Following `CLAUDE.md`: RED → GREEN → REFACTOR loop enforced at every change.

```bash
# Before every change:
make tdd-lint     # verify clean baseline

# RED phase:
# Write a failing test
make test         # must FAIL

# GREEN phase:
# Write minimal code to pass
make test         # must PASS

# REFACTOR phase:
# Improve code, keep tests passing
make tdd-lint     # lint check
make test         # must still PASS
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all targets |
| `make test` | Run all unit tests |
| `make test-race` | Unit tests with race detector |
| `make test-cover` | Unit tests with coverage profiles |
| `make lint` | go vet + gofmt check |
| `make lint-fix` | Auto-fix formatting + go vet |
| `make build` | Build binding-controller binary (→ `bin/`) |
| `make deploy` | Full deployment (phases 1-5) |
| `make deploy-p1` | Create kind clusters |
| `make deploy-p2` | Install Rook/Ceph on `us` |
| `make deploy-p3` | Register fleet on hub |
| `make deploy-p4` | Apply Kro GlobalBucket RGD |
| `make deploy-p5` | Start binding controller |
| `make deploy-p7` | Deploy LGTM stack + chainsaw CronJob |
| `make validate` | Run all Chainsaw E2E tests |
| `make validate-p1..p8` | Run individual phase test |
| `make grafana` | Port-forward Grafana → localhost:3000 |
| `make clean` | Destroy clusters and artifacts |
| `make all` | Full loop: lint → test → build → deploy → validate |

## Project Structure

```
.
├── deploy/platform-mvp/     # K8s manifests
│   ├── kind/                #   kind cluster configs
│   ├── rook/                #   CephCluster + ObjectStore CRs
│   ├── fleet/               #   ClusterProfile for spoke registration
│   ├── kro/                 #   GlobalBucket ResourceGraphDefinition
│   └── observability/       #   LGTM stack + dashboards + chainsaw CronJob
├── hack/platform-mvp/       # Shell scripts (called by Makefile)
├── pkg/
│   ├── multicluster/        #   Provider, Cluster, Aware interfaces
│   └── manager/             #   Manager wrapping a Provider
├── providers/
│   └── cluster-inventory-api/ # ClusterProfile-backed Provider impl
├── platform-mvp/
│   └── binding-controller/  #   RegionalBucket → spoke reconciler
│       └── controller/      #     Reconciler + tests
├── tests/e2e/               # Chainsaw test suites
│   └── tests/               #   01..08 progressive validation
├── docs/platform-mvp/       # Implementation docs per phase
├── .claude/                 # AI assistant working docs (plans/specs)
│   └── specs/               #   01..07 minimal specs
├── Makefile                 # Build, deploy, validate automation
└── README.md                # This file
```

## Cleanup

```bash
make clean            # destroy clusters, remove artifacts
make clean-artifacts  # remove bin/ and coverage files only
```

---

## License

© 2026 sojoner