# Platform MVP: Kro + multicluster-runtime on kind

A test-driven walkthrough of a multi-cluster platform, using
[Kro](https://github.com/kubernetes-sigs/kro) (ResourceGraphDefinition),
[multicluster-runtime](https://github.com/kubernetes-sigs/multicluster-runtime) and
[Chainsaw](https://github.com/kyverno/chainsaw) for declarative E2E validation — all running locally on `kind`.

**Concept**: a platform team exposes customer-facing APIs on a hub cluster with Kro. Binding controllers
(multicluster-runtime) place each order on the right spoke cluster and report status back. Two services run on it:

| Service | Order | Runs on |
|---------|-------|---------|
| VMs | `VmSet` — 1–3 small VMs, tier S or M | spoke `eu` (KubeVirt on KVM) |
| S3 buckets | `Bucket` — tier S or M with a quota | spoke `eu-storage` (Rook + Ceph RADOS Gateway) |

No cloud dependency.

## Documentation

The [documentation index](docs/platform-mvp/README.md) lists everything. Good entry points:

- [Architecture](docs/platform-mvp/architecture.md) — system context, components, key decisions
- [Domain model](docs/platform-mvp/domain-model.md) — vocabulary, bounded contexts, layering
- [Capabilities](docs/platform-mvp/capabilities.md) and [Use cases](docs/platform-mvp/use-cases.md) — what the platform offers and how each role uses it
- [Virtual machines](docs/platform-mvp/virtual-machines.md) and [Object storage](docs/platform-mvp/object-storage.md) — the two services
- [Build and deploy](docs/platform-mvp/build-and-deploy.md) — deploy order, trust bootstrap, development loop

## Why this architecture

The point is the pattern underneath; it is meant to hold up past a single kind demo:

- **Scales out without code changes.** A region is a `ClusterProfile` + kubeconfig Secret + spoke deployment. Controllers find clusters through ClusterProfile labels (`region`, `offers-vms`, `offers-object-storage`), with no per-region branches. See [`adding-a-region.md`](docs/platform-mvp/adding-a-region.md).
- **Tenancy is data, not schema.** A tenant is a `platform.example.com/tenant` label value, not a CRD field. Onboarding means a namespace + 3 RoleBindings (admin/developer/analyst) in `values.yaml`. See [`multi-tenancy.md`](docs/platform-mvp/multi-tenancy.md).
- **Split identity, least privilege, fail closed.** Controllers use audience-bound, Kubelet-rotated projected ServiceAccount tokens; humans use Dex OIDC. Each controller may write only its own resource kind in tenant namespaces (the bucket controller cannot read Secrets), the provider clears the fallback TLS cert so a missing token fails the request, and `ValidatingAdmissionPolicy` guardrails stop any non-admin from touching ClusterRoles or the auth config. See [Identity and trust](docs/platform-mvp/identity-and-trust.md).

## Architecture

```
 hub (kind-hub)                                spokes (one chart, per-spoke values)
 ┌──────────────────────────────┐   VMs     ┌──────────────────────────────┐
 │ Kro RGDs: VmSet, Bucket      │──────────▶│ eu          KubeVirt         │
 │   └─ Regional…Request        │           ├──────────────────────────────┤
 │ vm-binding-controller        │  claims   │ eu-storage  Rook + Ceph RGW  │
 │ bucket-binding-controller    │──────────▶├──────────────────────────────┤
 │ cluster-inventory Provider   │           │ us          plain spoke      │
 ├──────────────────────────────┤           └──────────────────────────────┘
 │ Observability                │            every spoke: tenant namespaces
 │  grafana prometheus loki     │            + RBAC, AuthenticationConfiguration,
 │  event-exporter ingress      │            oidc-verifier, admission guardrails
 │ Dex IDP · cert-manager       │
 │ chainsaw CronJob · Flux      │            host (bm4080.taildf7067.ts.net)
 └──────────────────────────────┘            Tailscale :30080 → hub:80, :30443 → hub:443
                                             grafana at /, dex at /dex
```

Controllers on the hub watch the requests there and act on the spokes; status flows back the same way.

| Cluster | Kubernetes | Purpose |
|---------|-----------|---------|
| `kind-hub` | 1.35 | Kro API, controllers, observability, Dex, cert-manager, Flux, ingress |
| `kind-us` | 1.30 | Plain spoke: tenant namespaces, oidc-verifier (no service hosted) |
| `kind-eu` | 1.35 | Spoke labelled `offers-vms`; KubeVirt (needs `/dev/kvm` on the host) |
| `kind-eu-storage` | 1.35 | Spoke labelled `offers-object-storage`; Ceph with a loop-device OSD |

`eu` and `eu-storage` both serve region `eu`; the bucket controller picks the cluster by the ClusterProfile `region` label.

## Prerequisites

| Tool | Min version | Check |
|------|-------------|-------|
| [Go](https://go.dev/dl/) | 1.23+ | `go version` |
| [Docker](https://docs.docker.com/engine/install/) | 24+ | `docker version` |
| [kind](https://kind.sigs.k8s.io/#installation) | 0.26+ | `kind version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.30+ | `kubectl version --client` |
| [Helm](https://helm.sh/docs/intro/install/) | 3.16+ | `helm version` |
| [Chainsaw](https://kyverno.github.io/chainsaw/latest/quick-start/) | v0.2.15 (pinned: `CHAINSAW_VERSION`) | `chainsaw version` |
| [Flux CLI](https://fluxcd.io/flux/installation/) | 2.4+ | `flux --version` |

```bash
make install-chainsaw
make install-flux
```

The `eu` spoke needs hardware virtualization (`/dev/kvm`); `eu-storage` needs the host's `/run/udev` (mounted into the node) so Ceph can find its loop device.

## Quick start

```bash
make all        # lint → test → build → deploy → validate
make grafana    # port-forward Grafana → http://localhost:3000 (admin/admin)
make clean      # destroy everything
```

### Step by step

```bash
make lint       # retired-reference guard + go vet + gofmt
make test       # unit tests (root + oidc-verifier + both binding controllers)
make build      # controller binaries → bin/
make deploy     # build images, create clusters, load images into kind, then 4 waves (CRDs → infra + spokes → hub services)
make validate   # the full Chainsaw E2E suite (29 tests)
```

### Dashboard links

After deployment, Grafana is at `http://bm4080.taildf7067.ts.net` (login `admin` / `admin`):

| Dashboard | URL | Shows |
|-----------|-----|-------|
| Cluster Fitness | [`/d/cluster-fitness`](http://bm4080.taildf7067.ts.net/d/cluster-fitness) | Node readiness, CPU, memory, API server health |
| Chainsaw Test Results | [`/d/chainsaw-results`](http://bm4080.taildf7067.ts.net/d/chainsaw-results) | E2E pass/fail, duration trends |
| Controller Deep Dive | [`/d/controller-deep-dive`](http://bm4080.taildf7067.ts.net/d/controller-deep-dive) | Reconcile throughput, latency, per-tenant breakdown |

```bash
make grafana-url   # print dashboard URLs
```

## Try it

Order a bucket for a tenant (on the hub), then read it on the storage spoke:

```bash
kubectl --context kind-hub apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: Bucket
metadata:
  name: media
  labels: { platform.example.com/tenant: acme-corp }
spec: { regions: [eu], size: S }
EOF
kubectl --context kind-hub get regionalbucketrequest media-eu -o jsonpath='{.status.regions[0].phase}{"\n"}'
kubectl --context kind-eu-storage -n acme-corp get objectbucketclaim,configmap,secret media-eu
```

VMs work the same way with a `VmSet`; see [Virtual machines](docs/platform-mvp/virtual-machines.md).

## Guided validation — Chainsaw test suites

`make validate` runs all 29 tests in order; each validates one layer. [Details per test](docs/platform-mvp/testing.md).

| Tests | Layer |
|-------|-------|
| 01–03 | Hub, `us` and fleet registration (ClusterProfile) |
| 04–06, 09, 11 | Observability: LGTM stack, CronJob, ingress and log shipping, dashboards |
| 07, 08, 12, 13 | Trust: Dex + oidc-verifier, projected SA tokens, `AuthenticationConfiguration` |
| 14, 16 | Guardrails: admission policies, platform-admin access |
| 10, 15 | Tenant isolation: claims land in the tenant namespace, no cross-tenant visibility |
| 17–23 | VM service: `eu`, KubeVirt, `VmSet` provisioning, lifecycle, cloud-init, console RBAC, unschedulable |
| 24–29 | Bucket service: `eu-storage`, Ceph RGW, `Bucket` provisioning with an S3 round trip, quotas, RBAC, unschedulable |

Run one test (from `tests/e2e`, where `.chainsaw.yaml` lives):

```bash
cd tests/e2e
chainsaw test --config .chainsaw.yaml tests/26-bucket-provisioning
```

## Development workflow (TDD)

```
🔴 RED → 🟢 GREEN → 🔄 REFACTOR
```

```bash
make lint && make test     # clean baseline before every change
# RED:      write the failing unit test (or Chainsaw test); it must fail
# GREEN:    minimal code; it must pass
# REFACTOR: improve, then make lint test again
make validate              # cluster behaviour
```

## Makefile targets

Run `make help` for the full list. The main ones:

| Target | Description |
|--------|-------------|
| `make all` | lint → test → build → deploy → validate |
| `make test` / `test-race` / `test-cover` | Unit tests (root + `GO_MODULES`) |
| `make lint` / `lint-fix` | Retired-reference guard, `go vet`, `gofmt` / auto-fix |
| `make build` | Controller binaries → `bin/` |
| `make build-images` / `load-images` | Build the Docker images / load them into the kind clusters (`make deploy` does both; no registry needed) |
| `make push-images` | Optional: push the images to `DOCKER_REGISTRY` to share them |
| `make deploy` | Clusters + 4 waves |
| `make deploy-wave1`…`4` | CRDs · infrastructure on hub · hub services · spokes |
| `make deploy-rook` | Rook/Ceph on `ROOK_SPOKES` (also part of wave 4) |
| `make deploy-cd` | Enable GitOps (Flux CD) on the hub |
| `make validate` | The full Chainsaw suite |
| `make chainsaw-runner` | Build + load the in-cluster Chainsaw runner (already part of `make deploy`) |
| `make grafana` / `grafana-url` | Port-forward / print dashboard URLs |
| `make verify-all` | Clean room: clean → deploy → validate → deploy-cd |
| `make clean` / `clean-artifacts` | Destroy clusters and artifacts / only `bin/` and coverage files |

## Project structure

```
.
├── deploy/platform-mvp/
│   ├── chart/                        # 4-wave Helm chart decomposition
│   │   ├── crds/                     #   Wave 1: Kro, ClusterProfile, cert-manager, Prometheus,
│   │   │                             #           RegionalVmSetRequest, RegionalBucketRequest CRDs
│   │   ├── infrastructure/           #   Wave 2: Dex, cert-manager issuer, dashboards, event-exporter,
│   │   │                             #           chainsaw CronJob, ingresses (+ LGTM, ingress-nginx deps)
│   │   ├── hub-services/             #   Wave 3: Kro controller, VmSet + Bucket RGDs, both binding
│   │   │                             #           controllers, fleet (ClusterProfiles), ServiceMonitor
│   │   └── spoke/                    #   Wave 4: one chart, values-{us,eu,eu-storage}.yaml
│   │                                 #           oidc-verifier, tenant RBAC, guardrails, KubeVirt, RBAC
│   ├── rook/                         # Rook operator + Ceph cluster values (eu-storage)
│   ├── flux/                         # Flux CD manifests
│   ├── kind/                         # hub config, spoke + storage-spoke templates
│   ├── crds/                         # Pre-fetched upstream CRD manifests
│   └── observability/                # Chainsaw runner image
├── hack/platform-mvp/                # Cluster wrappers, auth-config renderer
├── platform-mvp/
│   ├── vm-binding-controller/        # RegionalVmSetRequest → KubeVirt VMs (Go)
│   ├── bucket-binding-controller/    # RegionalBucketRequest → ObjectBucketClaim (Go)
│   └── oidc-verifier/                # JWKS-based JWT verifier (Go)
├── providers/cluster-inventory-api/  # ClusterProfile-backed multicluster Provider (Go)
├── tests/e2e/                        # Chainsaw suite (29 tests) + .chainsaw.yaml
├── docs/platform-mvp/                # Architecture and operations reference (start at README.md)
├── .claude/                          # Local planning notes (plans/specs, gitignored)
├── Makefile                          # Build, deploy, validate automation
└── README.md
```

## Cleanup

```bash
make clean            # destroy clusters (and detach the Ceph loop device), remove artifacts
make clean-artifacts  # remove bin/ and coverage files only
```

---

## License

© 2026 sojoner
