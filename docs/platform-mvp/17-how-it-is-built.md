# How the Platform Is Built

Short tour of the moving parts, the deploy order, and the dev loop. Architecture detail is in the [overview](00-overview.md).

## Building blocks

```mermaid
flowchart TB
    subgraph SRC["Repo"]
        RGD["Kro RGD<br/>chart/hub-services"]
        CRD["CRDs<br/>chart/crds"]
        BCS["binding-controller<br/>platform-mvp/"]
        PRV["cluster-inventory-api provider<br/>providers/"]
        SPK["spoke chart<br/>values-us / values-eu"]
        E2E["Chainsaw tests<br/>tests/e2e"]
    end
    subgraph HUB["Hub"]
        KRO["Kro"] --> RWR["RegionalWidgetRequest"]
        RWR --> BC["Binding controller"]
        PRV2["Provider"] -->|"engage"| BC
        CP["ClusterProfile<br/>+ kubeconfig Secret"] --> PRV2
    end
    subgraph SP["Spoke"]
        WO["Widget operator"]
        AU["AuthenticationConfiguration"]
    end
    RGD --> KRO
    CRD --> RWR
    BCS --> BC
    PRV --> PRV2
    SPK --> WO
    SPK --> AU
    BC -->|"Widget"| WO
```

Rule of thumb: **Kro owns the customer API**, **controllers own placement**, **the provider owns "which clusters exist"**.

## Deploy order

`make deploy` builds images, creates clusters, then installs in waves.

```mermaid
flowchart LR
    C["make clusters<br/>hub, then each spoke"] --> W1["Wave 1<br/>CRDs on hub + spokes"]
    W1 --> W2["Wave 2<br/>Infra on hub<br/>Dex, TLS, ingress, LGTM"]
    W1 --> W4["Wave 4<br/>Spokes<br/>one chart, per-spoke values"]
    W2 --> R["Refresh spoke auth config<br/>adds Dex CA"]
    W4 --> R
    R --> W3["Wave 3<br/>Hub services<br/>Kro, binding controller, fleet"]
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
| `platform-mvp/*` | Go services: binding-controller, widget-operator, oidc-verifier, dex-auth-plugin |
| `providers/cluster-inventory-api` | Multicluster provider; `SetLabelSelector` limits which clusters a controller engages |
| `deploy/platform-mvp/chart/{crds,infrastructure,hub-services,spoke}` | The four Helm charts |
| `deploy/platform-mvp/kind` | Hub config, spoke template |
| `tests/e2e/tests/NN-*` | One Chainsaw test per directory |
| `.claude/plans`, `.claude/specs` | Local planning notes (gitignored) |

## Extension points

| To add | Touch |
|--------|-------|
| A region | `SPOKES`, node image, `values-<name>.yaml`, `fleet.clusters`, `spokeTokens` |
| A tenant | `tenants:` in spoke values, Dex group |
| A service (e.g. VmSet 🚧) | CRD + Kro RGD + a controller that engages a labelled subset of spokes |
