# Use cases

The capabilities are listed in [Capabilities](capabilities.md). This page shows how each role uses them.

## Scenarios

| ID | As a | I want to | So that |
|----|------|-----------|---------|
| S1 | Platform admin | onboard a tenant with one values entry | the tenant gets a namespace and three roles on every spoke |
| S2 | Platform admin | order a bucket or VM set for a tenant in several regions with one object | I do not repeat work per region |
| S3 | Platform admin | add a region without changing controller code | the platform grows by configuration |
| S4 | Platform admin | see reconcile rates and errors per tenant and region | I can spot a failing tenant or region |
| S5 | Tenant admin | see my VMs, buckets and credentials | my team can use what was ordered |
| S6 | Tenant developer | open a console on my VM and use my bucket | I can work without any network exposure |
| S7 | Tenant analyst | read VMs, claims and status only | I can report without risk or seeing credentials |
| S8 | Tenant | be unable to see or touch another tenant | my data stays mine |
| S9 | Platform admin | order 1–3 small VMs, size S or M, for a tenant | the tenant gets a cheap Linux machine to try things on |
| S10 | Platform admin | order an S3 bucket, size S or M, for a tenant | the tenant gets object storage with a quota |

## S1 · Onboard a tenant

Add the tenant to `tenants:` in `chart/spoke/values.yaml` and its group to Dex, then `make deploy-wave4`.

```mermaid
sequenceDiagram
    actor PA as Platform admin
    participant V as chart/spoke values
    participant H as Helm
    participant S as Each spoke
    PA->>V: add tenant acme-corp + 3 Dex groups
    PA->>H: make deploy-wave4
    H->>S: Namespace acme-corp
    H->>S: Roles admin, developer, analyst
    H->>S: RoleBindings to dex:acme-corp-*
    S-->>PA: tenant ready on us, eu and eu-storage
```

## S2 · Order in several regions

Tenants have no identity on the hub, so the platform admin places the order on their behalf.

```yaml
apiVersion: platform.example.com/v1alpha1
kind: Bucket
metadata:
  name: media
  labels: { platform.example.com/tenant: acme-corp }
spec:
  regions: [eu, us]
  size: S
```

```mermaid
sequenceDiagram
    actor PA as Platform admin
    participant K as Kro (hub)
    participant B as Bucket binding controller
    participant ES as Spoke eu-storage
    PA->>K: apply Bucket
    K->>K: forEach region, one RegionalBucketRequest
    K-->>B: media-eu, media-us
    B->>ES: claim for media-eu in ns acme-corp
    B->>B: media-us has no object-storage cluster
    ES-->>B: claim Bound
    B-->>K: media-eu Ready, media-us Unschedulable
    K-->>PA: Bucket status lists both regions
```

A region that does not host the service is reported `Unschedulable` and creates nothing; the other regions are unaffected.

## S3 · Add a region

```mermaid
flowchart LR
    A["SPOKES += name<br/>+ KIND_NODE_IMAGE"] --> B["values-name.yaml<br/>token audience"]
    B --> C["fleet.clusters entry<br/>+ spokeTokens entry"]
    C --> D["make clusters deploy"]
    D --> E["Provider polls ClusterProfile<br/>engages the spoke"]
    E --> F["regions: name works"]
```

No Go code changes. `eu` and `eu-storage` were added this way. Steps: [Adding a region](adding-a-region.md).

## S5–S8 · Day to day on a spoke

```mermaid
sequenceDiagram
    actor U as Tenant user
    participant D as Dex
    participant A as Spoke API server
    U->>D: log in
    D-->>U: ID token with groups
    U->>A: read claim or VM in acme-corp
    A->>A: validate token (AuthenticationConfiguration)
    A->>A: RBAC by dex:acme-corp-* group
    alt allowed
        A-->>U: result
    else other tenant or missing right
        A-->>U: Forbidden
    end
```

| Role | read VMs / claims | VM console | read S3 credentials | create or delete | other tenant |
|------|:-----------------:|:----------:|:-------------------:|:----------------:|:------------:|
| admin | ✅ | ✅ | ✅ | ❌ | ❌ |
| developer | ✅ | ✅ | ✅ | ❌ | ❌ |
| analyst | ✅ | ❌ | ❌ | ❌ | ❌ |

Nobody but the platform creates or deletes VMs and claims; they come from the hub order. Tests 15, 22 and 28 simulate users with `--as` / `--as-group` and `SubjectAccessReview`.

## S4 · Watch the platform

```mermaid
flowchart LR
    BC["Bucket binding controller<br/>reconcile_total by tenant, region, result"] --> P["Prometheus"]
    V["OIDC verifier<br/>AUDIT lines"] --> EX["Event exporter + Promtail"]
    EX --> L["Loki"]
    CR["Chainsaw CronJob<br/>every 2 min"] --> L
    P --> G["Grafana<br/>Controller Deep Dive<br/>Cluster Fitness<br/>Chainsaw Results"]
    L --> G
```

## S9 · Order VMs

```mermaid
sequenceDiagram
    actor PA as Platform admin
    participant K as Kro (hub)
    participant VB as VM binding controller
    participant EU as Spoke eu (KubeVirt)
    actor T as Tenant
    PA->>K: VmSet {size S, replicas 2, ssh key}
    K->>K: S maps to 1 vCPU, 1 GiB
    K->>K: Secret with tenant label
    K-->>VB: RegionalVmSetRequest
    VB->>EU: copy Secret to ns acme-corp
    VB->>EU: create VirtualMachine x2
    EU-->>VB: VMs Running
    VB-->>K: status Ready, 2 of 2
    T->>EU: virtctl console (RBAC checked)
```

| Tier | vCPU | Memory |
|------|-----:|-------:|
| S | 1 | 1 GiB |
| M | 2 | 2 GiB |

Replicas scale down highest index first; deleting the `VmSet` removes its VMs and Secret from `eu`. Console access is enforced by RBAC (test 22); an interactive `virtctl console` session itself is not part of the automated suite. Tests 17–23.

## S10 · Order a bucket

```mermaid
sequenceDiagram
    actor PA as Platform admin
    participant K as Kro (hub)
    participant B as Bucket binding controller
    participant ES as Spoke eu-storage (Ceph RGW)
    actor T as Tenant admin
    PA->>K: Bucket {size S, regions [eu]}
    K->>K: S maps to 1 GiB, 10 000 objects
    K-->>B: RegionalBucketRequest
    B->>ES: ObjectBucketClaim in ns acme-corp
    ES-->>B: Bound, Secret + ConfigMap written
    B-->>K: status Ready, endpoint
    T->>ES: read credentials and endpoint in own namespace
```

| Tier | Max size | Max objects |
|------|---------:|------------:|
| S | 1 GiB | 10 000 |
| M | 10 GiB | 100 000 |

Ceph refuses writes past the quota (test 27); deleting the `Bucket` removes the claim, Secret and ConfigMap. Details: [Object storage](object-storage.md). Tests 24–29.
