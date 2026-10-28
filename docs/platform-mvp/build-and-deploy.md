# Build and deploy

How the platform is built from this repository, the order in which it is deployed, and the development loop. The system design is in the [Architecture](architecture.md); the vocabulary in the [Domain model](domain-model.md). Clusters are [kind](https://kind.sigs.k8s.io/) clusters and every component is installed with [Helm](https://helm.sh/docs/) charts; [Flux](https://fluxcd.io/flux/) can take over the hub charts (`make deploy-cd`).

## Building blocks

```mermaid
flowchart TB
    subgraph SRC["Repo"]
        RGD["Kro RGDs<br/>chart/hub-services"]
        CRD["CRDs<br/>chart/crds"]
        VBCS["vm-binding-controller<br/>platform-mvp/"]
        BBCS["bucket-binding-controller<br/>platform-mvp/"]
        PRV["cluster-inventory-api provider<br/>providers/"]
        SPK["spoke chart<br/>values-us / values-eu / values-eu-storage"]
        ROOK["Rook values<br/>deploy/platform-mvp/rook"]
        E2E["Chainsaw tests<br/>tests/e2e"]
    end
    subgraph HUB["Hub"]
        KRO["Kro"] --> REQ["RegionalVmSetRequest<br/>RegionalBucketRequest"]
        REQ --> BC["Binding controllers"]
        PRV2["Provider"] -->|"engage"| BC
        CP["ClusterProfile<br/>+ kubeconfig Secret"] --> PRV2
    end
    subgraph SP["Spokes"]
        KV["KubeVirt (eu)"]
        RK["Rook + Ceph (eu-storage)"]
        AU["AuthenticationConfiguration"]
    end
    RGD --> KRO
    CRD --> REQ
    VBCS --> BC
    BBCS --> BC
    PRV --> PRV2
    SPK --> AU
    ROOK --> RK
    BC -->|"VMs"| KV
    BC -->|"claims"| RK
```

Rule of thumb: **Kro owns the customer API**, **controllers own placement**, **the provider owns "which clusters exist"**.

## The binding controllers

Both are built test first in the same layers. Decisions live in pure packages; only `controller` touches clusters.

```mermaid
flowchart TB
    M["main.go<br/>wiring"] --> CFG["config<br/>flags to validated Config"]
    M --> CTL["controller<br/>impure shell: clients, finalizer, requeue"]
    CTL --> AD["adapter<br/>pure: objects to domain, manifests"]
    CTL --> DOM["domain<br/>pure: plan, status, tenant and region rules"]
    AD --> DOM
```

```mermaid
flowchart LR
    R["Request on hub"] --> F["add finalizer"]
    F --> C{"engaged cluster for the region?"}
    C -->|"no"| U["status Unschedulable<br/>requeue"]
    C -->|"yes"| S["create or update spoke objects"]
    S --> T["status from spoke state"]
    E["Spoke event"] --> T
```

Two watches share one manager: requests on the hub, VMs or claims on every engaged spoke. The provider engages only clusters matching `--cluster-selector` (`offers-vms=true` or `offers-object-storage=true`), so `us` never sees service work. Details: [Placement controllers](placement-controllers.md).

## Deploy order

`make deploy` builds the images and creates the clusters, loads the images into kind (no registry, no push; the charts use `pullPolicy: IfNotPresent`), then installs in waves.

```mermaid
flowchart LR
    C["make clusters<br/>hub, then each spoke"] --> W1["Wave 1<br/>CRDs on hub + spokes"]
    W1 --> W2["Wave 2<br/>Infra on hub<br/>Dex, TLS, ingress, LGTM"]
    W1 --> W4["Wave 4<br/>Spokes<br/>one chart, per-spoke values<br/>KubeVirt on eu, Rook on eu-storage"]
    W2 --> R["Refresh spoke auth config<br/>adds Dex CA"]
    W4 --> R
    R --> W3["Wave 3<br/>Hub services<br/>Kro, binding controllers, fleet"]
    W3 --> V["make validate"]
```

## Why hub comes first

A spoke API server reads its auth config at boot, and that config needs the hub's CA. So clusters cannot start in parallel.

```mermaid
flowchart LR
    H["Create hub"] --> CA["Read hub CA"]
    CA --> AC["Render spoke<br/>AuthenticationConfiguration"]
    AC --> S["Create spoke<br/>mounts the file"]
    S --> D["Dex CA added after Wave 2<br/>apiserver hot-reloads"]
```

## Dev loop

```mermaid
flowchart LR
    R["RED<br/>failing test"] --> G["GREEN<br/>minimal code"]
    G --> F["REFACTOR"]
    F --> L["make lint test"]
    L --> V["make validate"]
    V --> CM["you commit"]
    CM --> R
```

- Unit tests first for pure logic; Chainsaw tests first for cluster behaviour.
- Config lives in Helm values and Makefile variables, never in code.

## Where things live

| Path | What |
|------|------|
| `platform-mvp/*` | Go services: vm-binding-controller, bucket-binding-controller, oidc-verifier |
| `providers/cluster-inventory-api` | Multicluster provider; `SetLabelSelector` limits which clusters a controller engages |
| `deploy/platform-mvp/chart/{crds,infrastructure,hub-services,spoke}` | The four Helm charts |
| `deploy/platform-mvp/kind` | Hub config, spoke templates (plain and storage) |
| `deploy/platform-mvp/rook` | Rook operator and Ceph cluster values for `eu-storage` |
| `tests/e2e/tests/NN-*` | One Chainsaw test per directory |
| `.claude/plans`, `.claude/specs` | Local planning notes (gitignored) |

## Extension points

| To add | Touch |
|--------|-------|
| A region | `SPOKES`, node image, `values-<name>.yaml` (audience), `fleet.clusters` (`region` label), the serving controller's `spokeTokens` |
| A tenant | `tenants:` in spoke values, Dex group |
| A service (VmSet, Bucket) | Request CRD + Kro RGD + a controller (copy the layers) that engages an `offers-<service>` subset of spokes + spoke RBAC |
