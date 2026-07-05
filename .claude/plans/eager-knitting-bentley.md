# Platform MVP: Kro + multicluster-runtime + Rook-Ceph on kind

## Context

Goal: prove a platform architecture where a platform team defines an abstract customer-facing API (`GlobalBucket`) via **Kro** on a hub cluster, and a **multicluster-runtime**-based binding controller fans the expanded intent out to a workload ("spoke") cluster running **Rook/Ceph** with an RGW S3 gateway — entirely on local `kind` clusters, no cloud dependency.

This validates the missing link identified in research: Kro is single-cluster by design (it expands a `ResourceGraphDefinition` into child objects on the same API server it runs on) and has no concept of placing objects on a different cluster. multicluster-runtime is the natural fit for that placement step, but this combination has no known prior art — this MVP is the first concrete test of the pattern.

**Scope for this MVP** (per user decision): hub cluster + **one** spoke region (`us`) with a real Rook/Ceph cluster and RGW. EU/ASIA are not stood up, but the design is written so adding them later is "repeat phase 1–2 with a new kind cluster + ClusterProfile," not a redesign.

**Deliverable form**: this plan, and the phase spec `.md` files it describes, are handed to a separate implementation agent (32 cores / 64GB / 2TB available) — so each phase below is written to become its own standalone spec file with enough detail to implement without re-deriving context from this conversation.

**Known risk, called out up front**: real Ceph OSDs need block devices. kind nodes are plain Docker containers with no raw disks. The only workable path (confirmed via Rook's own CI approach, which uses real block devices, not kind) is community-pattern loop devices attached into kind's node containers. This is less battle-tested than Rook's CI path. Phase 2 includes a verification checkpoint and a documented fallback (single-OSD, smallest possible loop file, `replicated.size: 1`) if the naive approach is flaky — the fallback is still real Rook/Ceph, just minimal, not a mock.

## Deliverables

Create `docs/platform-mvp/` in this repo with:
- `00-overview.md` — this plan, trimmed to an index + architecture diagram description
- `01-kind-topology.md`
- `02-rook-ceph-spoke.md`
- `03-fleet-registration.md`
- `04-kro-globalbucket-api.md`
- `05-binding-controller.md`
- `06-e2e-verification.md`
- `99-extending-to-eu-asia.md` (design-only, not implemented)

Each phase file follows the same structure: Goal, Prerequisites, Steps (exact commands/manifests), Files produced, Acceptance criteria.

---

## Phase 1 — kind topology (`01-kind-topology.md`)

**Goal**: two reachable kind clusters, `hub` and `us`.

- `kind create cluster --name hub --config kind-hub.yaml`
- `kind create cluster --name us --config kind-us.yaml` — `us` config requests **3 worker nodes** (Ceph mon quorum needs odd node spread even at minimal replication; 1 control-plane + 3 workers keeps OSD placement simple)
- Cross-cluster reachability: kind clusters share the `kind` Docker network by default — hub can reach `us`'s API server via its container IP/port. Binding controller will use a kubeconfig with that address (not `127.0.0.1`) — this file documents extracting it: `kind get kubeconfig --name us --internal` gives the in-Docker-network address, needed because the binding controller will itself run as a pod on `hub` eventually (or as a local process for MVP — both addressing modes documented).
- Files produced: `kind-hub.yaml`, `kind-us.yaml`, `hack/platform-mvp/create-clusters.sh`, `hack/platform-mvp/destroy-clusters.sh`
- Acceptance: `kubectl --context kind-hub get nodes` and `kubectl --context kind-us get nodes` both succeed; `docker exec kind-us-control-plane ping -c1 <hub-apiserver-ip>` succeeds (proves network reachability for the binding controller's later cross-cluster calls).

## Phase 2 — Rook/Ceph + RGW on `us` (`02-rook-ceph-spoke.md`)

**Goal**: real S3-compatible endpoint on `us` via Rook-managed Ceph RGW.

- Inject loop-device-backed block storage into each `us` worker node **before** installing Rook:
  - `hack/platform-mvp/attach-loop-devices.sh`: for each `us` worker container, `docker exec <node> truncate -s 10G /var/lib/rook-loopfile`, then `docker exec <node> losetup -f /var/lib/rook-loopfile` inside that container's namespace (containers are privileged by kind by default, giving access to `/dev/loop-control`). Confirm with `docker exec <node> losetup -a`.
  - Label each node's discovered loop device is picked up by Rook's device discovery (`useAllDevices: true` in the CephCluster CR — Rook's `discover-agent` DaemonSet scans `/dev` inside each node).
- Install Rook operator: `kubectl --context kind-us apply -f https://raw.githubusercontent.com/rook/rook/<pinned-tag>/deploy/examples/crds.yaml,common.yaml,operator.yaml` (pin an exact Rook release tag — do not float `master`).
- Apply a CephCluster CR modeled on `cluster-test.yaml` (`mon.count: 1`, `mgr.count: 1`, `useAllDevices: true`, pool `replicated.size: 1`, `requireSafeReplicaSize: false`) — minimal single-replica posture appropriate for an MVP, not production.
- Apply `object-test.yaml`-style `CephObjectStore` (`gateway.instances: 1`, `metadataPool`/`dataPool` `replicated.size: 1`) to bring up RGW.
- Verification checkpoint (do this before moving on — this is the risk area): `kubectl --context kind-us -n rook-ceph exec deploy/rook-ceph-tools -- ceph status` must show `HEALTH_OK` or `HEALTH_WARN` (not `HEALTH_ERR`) and OSDs `up`/`in`. If OSDs never come up, fallback: reduce to a single worker node + single loop device + `mon.count: 1`, `osd count: 1` before escalating further.
- Files produced: `hack/platform-mvp/attach-loop-devices.sh`, `deploy/platform-mvp/rook/cluster.yaml`, `deploy/platform-mvp/rook/object-store.yaml`
- Acceptance: `ceph status` healthy; RGW service reachable in-cluster (`kubectl --context kind-us -n rook-ceph get svc rook-ceph-rgw-my-store`); a manual test bucket creation via the toolbox (`radosgw-admin bucket list` / a `s3cmd`/`awscli` pod hitting the RGW ClusterIP) succeeds — this proves the S3 surface works before any Kro/multicluster-runtime code touches it.

## Phase 3 — Fleet registration (`03-fleet-registration.md`)

**Goal**: `hub` knows about `us` as a named cluster via the `cluster-inventory-api` provider (already vendored in this repo at `providers/cluster-inventory-api`).

- Install the `ClusterProfile` CRD (from `sigs.k8s.io/cluster-inventory-api`) on `hub`.
- Create a Secret on `hub` holding `us`'s kubeconfig (internal address from Phase 1) and a `ClusterProfile` named `us` referencing it — mirror the wiring in this repo's `examples/cluster-inventory-api/setup-kind-demo.sh`, adapted for one spoke instead of one.
- Files produced: `deploy/platform-mvp/fleet/clusterprofile-us.yaml`, `hack/platform-mvp/register-fleet.sh`
- Acceptance: a small throwaway Go program (or reuse of the existing `examples/cluster-inventory-api` binary pointed at this ClusterProfile) using `providers/cluster-inventory-api` successfully calls `Get(ctx, "us")` and returns a working `cluster.Cluster` whose client can `List` nodes on `us`.

## Phase 4 — Kro `GlobalBucket` API (`04-kro-globalbucket-api.md`)

**Goal**: hub-only Kro RGD that expands one customer-facing object into per-region intents (only `us` populated for this MVP, but schema supports a list).

- Install Kro on `hub` (Helm chart per kro.run docs, pinned version).
- Author `ResourceGraphDefinition` `GlobalBucket`:
  - Schema: `spec.regions: []string` (enum-ish, values `us`/`eu`/`asia` documented even though only `us` is wired), `spec.sizeGiB: int`, `spec.versioned: bool`.
  - Template: `forEach` over `spec.regions`, emitting one `RegionalBucketRequest` custom resource per region (group e.g. `platform.example.com/v1alpha1`, fields `region`, `sizeGiB`, `versioned`, owner-referenced back to the `GlobalBucket`).
- Files produced: `deploy/platform-mvp/kro/globalbucket-rgd.yaml`
- Acceptance: `kubectl --context kind-hub apply -f globalbucket-rgd.yaml` registers CRDs `globalbuckets.<group>` and `regionalbucketrequests.<group>`; applying a sample `GlobalBucket{regions: [us]}` produces exactly one `RegionalBucketRequest` named deterministically (e.g. `<globalbucket-name>-us`) — verify with `kubectl get regionalbucketrequests -o yaml`. No multicluster-runtime code involved yet — this phase is pure Kro.

## Phase 5 — Binding controller (`05-binding-controller.md`)

**Goal**: a standalone Go program (new module, e.g. `platform-mvp/binding-controller/`) that watches `RegionalBucketRequest` on `hub` only, and for each one, creates the corresponding Rook objects on the target spoke.

- Because `RegionalBucketRequest` is a CRD generated dynamically by Kro (no generated Go types), the controller must use `unstructured.Unstructured` with the GVK set explicitly, registered via the multicluster-runtime builder (mirrors how controller-runtime's own `builder.For()` supports unstructured types).
- Controller setup:
  - `mgr := mcmanager.New(hubRestConfig, provider, opts)` where `provider` is `cluster-inventory-api`'s provider pointed at `hub`'s ClusterProfiles (from Phase 3) — note the provider here is used only for **outbound** lookups (`mgr.GetCluster(ctx, "us")`), the controller's own watch stays on `hub`.
  - Reconciler logic: on `RegionalBucketRequest` create/update, read `.spec.region`; `cl, err := mgr.GetCluster(ctx, mcmanager.ClusterName(region))`; using `cl.GetClient()`, upsert a `CephObjectStoreUser` (Rook's typed API, `github.com/rook/rook/pkg/apis/ceph.rook.io/v1`, import the client-go types — no need for unstructured here since Rook ships real Go types) named after the request, referencing the `CephObjectStore` from Phase 2.
  - Also create an `ObjectBucketClaim` (lib-bucket-provisioner API) on `us` so Rook's bucket provisioner creates the actual bucket + credentials Secret.
  - Status propagation: watch the OBC's status/Secret on `us` (a **second**, spoke-side watch — this is the point where multicluster-runtime's normal multi-cluster fan-out is actually used, as opposed to Phase 5's hub-only watch) and copy `{region, endpoint, bucketName, secretRef}` (not raw keys) into `RegionalBucketRequest.status` on `hub`, which Kro/owner-reference bubbles up to `GlobalBucket.status`.
- Files produced: `platform-mvp/binding-controller/main.go`, `platform-mvp/binding-controller/controller.go`, `platform-mvp/binding-controller/go.mod`
- Acceptance: with Phases 1–4 up, running the binding controller and then applying a `GlobalBucket{regions:[us]}` on `hub` results in a real `CephObjectStoreUser` + `ObjectBucketClaim` on `us`, a bound Secret with S3 credentials, and `GlobalBucket.status.regions[0].endpoint` populated on `hub`.

## Phase 6 — E2E verification (`06-e2e-verification.md`)

**Goal**: prove the full loop with a real S3 call, scripted and repeatable.

- `hack/platform-mvp/e2e.sh`: creates clusters (Phase 1) → sets up Rook (Phase 2) → registers fleet (Phase 3) → installs Kro RGD (Phase 4) → runs binding controller (Phase 5) → applies a sample `GlobalBucket` → polls `GlobalBucket.status` until ready → reads the credentials Secret from `us` → runs a one-shot pod (or local `aws s3 --endpoint-url` call via port-forward) doing `PutObject`/`GetObject` against the RGW endpoint → asserts success.
- Acceptance: script exits 0; document manual teardown (`hack/platform-mvp/destroy-clusters.sh`).

## Phase 99 — Extending to EU/ASIA (`99-extending-to-eu-asia.md`, design-only)

Document, without implementing: repeat Phase 1 (new kind cluster) + Phase 2 (Rook/Ceph in it) + Phase 3 (new ClusterProfile) per region; Phase 4's RGD already supports arbitrary region lists; Phase 5's binding controller already does `mgr.GetCluster(ctx, ClusterName(region))` generically — no code change needed there, only fleet registration growth. Call out that 3 concurrent Ceph clusters is a real resource commitment (network + CPU) worth doing on a bigger box, which is why this MVP validates with one spoke first.

## Addendum — gap remediation (2026-07-05)

Two gaps found on review, both fixed:

1. **multicluster-runtime was never actually adopted.** `pkg/multicluster`/`pkg/manager` were hand-rolled look-alikes (`Provider`/`Cluster`/`Manager` interfaces mimicking the shape, no real dependency on `sigs.k8s.io/multicluster-runtime`). Fixed by adding the real dependency (pinned to `v0.20.4-alpha.7` — the earliest release under the `sigs.k8s.io` module path; matches this repo's existing `go 1.23` / `controller-runtime v0.20.x` / `k8s.io/* v0.32.x` pins closely, avoiding the `go 1.25` / `controller-runtime v0.23.1` / `k8s.io/* v0.35.0` jump required by later releases) and deleting the hand-rolled packages entirely. `providers/cluster-inventory-api` now implements the real `multicluster.Provider` interface, including a `Run(ctx, mcmanager.Manager)` discovery loop that polls `ClusterProfile` objects and calls `mgr.Engage(...)` — the actual cross-cluster fan-out mechanism Phase 5 originally called for but never got.
2. **Status propagation was incomplete.** The binding controller only ever wrote `{region, phase}` to `RegionalBucketRequest.status.regions`, never the `{endpoint, bucketName, secretRef}` Phase 5 specified. Fixed by adding a second reconciler (`StatusReconciler`, in `platform-mvp/binding-controller/controller/status_reconciler.go`) built via `mcbuilder.ControllerManagedBy` watching `ObjectBucketClaim` across engaged spoke clusters — this is the "second, spoke-side watch" Phase 5 described. It resolves the OBC's bound `ObjectBucket` (`spec.connection.endpoint`) and references the credentials `Secret` (by name/namespace only, never reading its contents), then writes the full shape back to the hub.

Side effect of the Reconciler A rewrite: the original `SetupWithManager` called bare `controller.New(...)` without ever calling `.Watch(...)` — a latent bug where the controller was registered but never actually received events. Switching to the builder pattern (`ctrl.NewControllerManagedBy(...).For(...).Complete(...)`) fixed this as part of the interface swap.

See revised acceptance criteria in `.claude/specs/05-binding-controller.md`.

## Addendum — packaging and deployment gap (2026-07-05)

Review found the binding controller had no path from source to a running workload: no `Dockerfile`, no `Deployment` in `chart/hub`, and a dead `ServiceMonitor` (`chart/hub/templates/servicemonitors.yaml`) already selecting `app: binding-controller` with nothing behind it. Chainsaw test `06-binding-controller.yaml` only ever passed because a human manually ran `go run .` beforehand — the chart/Flux/CronJob deployment loop never actually exercised it.

Also found, while wiring this up, a latent bug that would have surfaced the moment the controller ran via the real (non-static) provider in-cluster: `providers/cluster-inventory-api/provider.go`'s `ClusterProfileGVK` was hardcoded to `cluster.x-k8s.io/v1beta1`, but the actually-installed `ClusterProfile` CRD (applied in `make deploy-hub` from cluster-inventory-api upstream, and used by every `ClusterProfile` manifest in this repo) is `multicluster.x-k8s.io/v1alpha1`. The existing unit test asserted against the same wrong constant, so it never caught the mismatch — only listing real cluster-scoped `ClusterProfile` objects during live packaging work exposed it. Fixed test-first (RED: correct the test's expected GVK, confirm it fails against the old constant; GREEN: fix the constant) — this had been silently masked in earlier live verification because that test run used `--spoke-kubeconfig` (the static-provider path), which never goes through `ClusterProfileGVK` discovery at all.

Fixed:

- `platform-mvp/binding-controller/Dockerfile` — multi-stage build; build context must be the repo root (not the module directory) since the module's `go.mod` has a local `replace` to the root module.
- `chart/hub/templates/binding-controller.yaml` — `ServiceAccount` + `ClusterRole`/`ClusterRoleBinding` (hub-only RBAC: `regionalbucketrequests[/status]`, `clusterprofiles`, `secrets`) + `Deployment` + `Service`, all in the `default` namespace to match the existing `ServiceMonitor`'s `namespaceSelector`. No `--hub-kubeconfig`/`--spoke-kubeconfig` args are passed — in-cluster, `main.go`'s `clientcmd.BuildConfigFromFlags("", "")` falls back to `rest.InClusterConfig()` automatically, and the dynamic `ClusterProfile`-based provider (now fixed) handles spoke discovery.
- `chart/hub/values.yaml` — `bindingController.{replicas,metricsPort,image,resources}`, externalized per CLAUDE.md (no magic numbers baked into the template).
- `Makefile` — `binding-controller-image` target (`docker build` + `kind load docker-image`, mirroring the existing `chainsaw-runner` target), wired as a prerequisite of `deploy-hub`.

## Upstream references (pin exact versions when implementing — do not float `master`/`latest`)

- **Kro**: https://kro.run/docs/overview/ · RGD concept: https://kro.run/docs/concepts/rgd/overview/ · source: https://github.com/kubernetes-sigs/kro · install via Helm chart published from that repo's releases (pick latest tagged, e.g. check `https://github.com/kubernetes-sigs/kro/releases` at implementation time).
- **Rook**: source https://github.com/rook/rook · pin a release branch/tag, e.g. `release-1.16`, not `master`, for all raw manifest URLs below:
  - CRDs/common/operator: `https://raw.githubusercontent.com/rook/rook/<tag>/deploy/examples/{crds,common,operator}.yaml`
  - Minimal test cluster reference: `https://raw.githubusercontent.com/rook/rook/<tag>/deploy/examples/cluster-test.yaml`
  - Minimal object store reference: `https://raw.githubusercontent.com/rook/rook/<tag>/deploy/examples/object-test.yaml`
  - PVC-based OSD reference (context only, not used — confirms block-mode requirement): `https://raw.githubusercontent.com/rook/rook/<tag>/deploy/examples/cluster-on-pvc.yaml`
  - Rook's own CI device-prep scripts (pattern to adapt for kind, since Rook's CI itself uses minikube/bare VMs, not kind): `https://github.com/rook/rook/blob/master/tests/scripts/github-action-helper.sh` and `.../create-bluestore-partitions.sh`
  - Known gap re: loop devices: https://github.com/rook/rook/issues/7206
  - Community kind recipe consulted for the loop-device-into-container-node pattern: https://oneuptime.com/blog/post/2026-03-31-rook-deploy-rook-ceph-kind-kubernetes-in-docker/view (verify still current at implementation time; treat as a pattern reference, not a copy-paste source)
  - Object Bucket Claim API (`lib-bucket-provisioner`): https://github.com/kube-object-storage/lib-bucket-provisioner
- **cluster-inventory-api** (`ClusterProfile` CRD): https://github.com/kubernetes-sigs/cluster-inventory-api
- **multicluster-runtime** (this repo): provider used is `providers/cluster-inventory-api/provider.go`; pattern for Secret+ClusterProfile wiring to copy/adapt is `examples/cluster-inventory-api/setup-kind-demo.sh` and `examples/cluster-inventory-api/e2e-incluster.sh`; core interfaces this plan relies on are `pkg/multicluster/multicluster.go` (`Provider`, `Aware`) and `pkg/manager/manager.go` (`Manager.GetCluster`).
- **kind**: multi-cluster-on-shared-Docker-network behavior and `--internal` kubeconfig flag: https://kind.sigs.k8s.io/docs/user/configuration/ and `kind get kubeconfig --help`.

## Verification (overall)

Since this is a from-scratch build with no existing tests to run: each phase's own acceptance criteria (above) is the test for that phase. The Phase 6 e2e script is the end-to-end proof the whole plan is required to produce. No phase should be marked done without its acceptance criteria demonstrated live against real kind clusters — this is infrastructure, not something a unit test can substitute for.
