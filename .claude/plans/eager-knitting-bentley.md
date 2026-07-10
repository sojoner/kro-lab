# Platform MVP: Kro + multicluster-runtime + a spoke operator on kind

## Context

Goal: prove a platform architecture where a platform team defines an abstract customer-facing API (`GlobalWidget`) via **Kro** on a hub cluster, and a **multicluster-runtime**-based binding controller fans the expanded intent out to a workload ("spoke") cluster running a small downstream operator — entirely on local `kind` clusters, no cloud dependency.

This validates the missing link identified in research: Kro is single-cluster by design (it expands a `ResourceGraphDefinition` into child objects on the same API server it runs on) and has no concept of placing objects on a different cluster. multicluster-runtime is the natural fit for that placement step, but this combination has no known prior art — this MVP is the first concrete test of the pattern.

**Scope for this MVP** (per user decision): hub cluster + **one** spoke region (`us`) running a minimal reconciler. EU/ASIA are not stood up, but the design is written so adding them later is "repeat phase 1–2 with a new kind cluster + ClusterProfile," not a redesign.

**Deliverable form**: this plan, and the phase spec `.md` files it describes, are handed to a separate implementation agent — so each phase below is written to become its own standalone spec file with enough detail to implement without re-deriving context from this conversation.

**Pivot (2026-07-10)**: the original plan used a real Rook-managed Ceph cluster on `us` as the downstream payload. That was abandoned after a multi-hour live debugging session (see Addendum below) hit a hard environmental wall unrelated to the pattern this MVP exists to prove. The spoke payload is now a trivial `Widget` CRD + operator that just flips status fields — this removes an entire unrelated failure domain (block storage in Docker-in-Docker) while preserving every phase's structure and the thing actually being tested: cross-cluster placement and status propagation.

## Deliverables

Create `docs/platform-mvp/` in this repo with:
- `00-overview.md` — this plan, trimmed to an index + architecture diagram description
- `01-kind-topology.md`
- `02-widget-operator.md`
- `03-fleet-registration.md`
- `04-kro-globalwidget-api.md`
- `05-binding-controller.md`
- `06-e2e-verification.md`
- `99-extending-to-eu-asia.md` (design-only, not implemented)

Each phase file follows the same structure: Goal, Prerequisites, Steps (exact commands/manifests), Files produced, Acceptance criteria.

---

## Phase 1 — kind topology (`01-kind-topology.md`)

**Goal**: two reachable kind clusters, `hub` and `us`.

- `kind create cluster --name hub --config kind-hub.yaml`
- `kind create cluster --name us --config kind-us.yaml` — single control-plane + single worker is sufficient; `us` no longer runs any stateful workload with node-count/replica requirements.
- Cross-cluster reachability: kind clusters share the `kind` Docker network by default — hub can reach `us`'s API server via its container IP/port. Binding controller will use a kubeconfig with that address (not `127.0.0.1`) — this file documents extracting it: `kind get kubeconfig --name us --internal` gives the in-Docker-network address, needed because the binding controller will itself run as a pod on `hub` eventually (or as a local process for MVP — both addressing modes documented).
- Files produced: `kind-hub.yaml`, `kind-us.yaml`, `hack/platform-mvp/create-clusters.sh`, `hack/platform-mvp/destroy-clusters.sh`
- Acceptance: `kubectl --context kind-hub get nodes` and `kubectl --context kind-us get nodes` both succeed; `docker exec kind-us-control-plane ping -c1 <hub-apiserver-ip>` succeeds (proves network reachability for the binding controller's later cross-cluster calls).

## Phase 2 — spoke operator (`02-widget-operator.md`)

**Goal**: a minimal, real (non-mock) reconciler running on `us` that the binding controller can create objects against and watch status on — standing in for whatever a real downstream integration would be, without dragging in that integration's own operational complexity.

- Define a `Widget` CRD (group e.g. `platform.example.com/v1alpha1`): `spec.message: string`, `status.phase: Pending|Ready`, `status.endpoint: string`.
- A small Go controller-runtime operator (`platform-mvp/widget-operator/`, single-cluster, no multicluster-runtime involved here — it only ever talks to its own cluster's API server) reconciles `Widget`: on create, after a short simulated delay (e.g. 2s, config-driven not hardcoded), sets `status.phase = Ready` and `status.endpoint = fmt.Sprintf("widget://%s/%s", req.Namespace, req.Name)`. The delay exists specifically so Phase 5's status-propagation watch has something real to observe rather than a same-tick synchronous write.
- Files produced: `platform-mvp/widget-operator/{main.go,controller.go,go.mod}`, `deploy/platform-mvp/widget-operator/crd.yaml`, `platform-mvp/widget-operator/Dockerfile`
- Acceptance: applying a `Widget` on `us` directly (no binding controller involved yet) transitions to `status.phase: Ready` with `status.endpoint` populated within a few seconds.

## Phase 3 — Fleet registration (`03-fleet-registration.md`)

**Goal**: `hub` knows about `us` as a named cluster via the `cluster-inventory-api` provider (already vendored in this repo at `providers/cluster-inventory-api`).

- Install the `ClusterProfile` CRD (from `sigs.k8s.io/cluster-inventory-api`) on `hub`.
- Create a Secret on `hub` holding `us`'s kubeconfig (internal address from Phase 1) and a `ClusterProfile` named `us` referencing it — mirror the wiring in this repo's `examples/cluster-inventory-api/setup-kind-demo.sh`, adapted for one spoke instead of one.
- Files produced: `deploy/platform-mvp/fleet/clusterprofile-us.yaml`, `hack/platform-mvp/register-fleet.sh`
- Acceptance: a small throwaway Go program (or reuse of the existing `examples/cluster-inventory-api` binary pointed at this ClusterProfile) using `providers/cluster-inventory-api` successfully calls `Get(ctx, "us")` and returns a working `cluster.Cluster` whose client can `List` nodes on `us`.

## Phase 4 — Kro `GlobalWidget` API (`04-kro-globalwidget-api.md`)

**Goal**: hub-only Kro RGD that expands one customer-facing object into per-region intents (only `us` populated for this MVP, but schema supports a list).

- Install Kro on `hub` (Helm chart per kro.run docs, pinned version).
- Author `ResourceGraphDefinition` `GlobalWidget`:
  - Schema: `spec.regions: []string` (enum-ish, values `us`/`eu`/`asia` documented even though only `us` is wired), `spec.message: string`.
  - Template: `forEach` over `spec.regions`, emitting one `RegionalWidgetRequest` custom resource per region (group e.g. `platform.example.com/v1alpha1`, fields `region`, `message`, owner-referenced back to the `GlobalWidget`).
- Files produced: `deploy/platform-mvp/kro/globalwidget-rgd.yaml`
- Acceptance: `kubectl --context kind-hub apply -f globalwidget-rgd.yaml` registers CRDs `globalwidgets.<group>` and `regionalwidgetrequests.<group>`; applying a sample `GlobalWidget{regions: [us]}` produces exactly one `RegionalWidgetRequest` named deterministically (e.g. `<globalwidget-name>-us`) — verify with `kubectl get regionalwidgetrequests -o yaml`. No multicluster-runtime code involved yet — this phase is pure Kro.

## Phase 5 — Binding controller (`05-binding-controller.md`)

**Goal**: a standalone Go program (`platform-mvp/binding-controller/`) that watches `RegionalWidgetRequest` on `hub` only, and for each one, creates the corresponding `Widget` on the target spoke.

- Because `RegionalWidgetRequest` is a CRD generated dynamically by Kro (no generated Go types), the controller must use `unstructured.Unstructured` with the GVK set explicitly, registered via the multicluster-runtime builder (mirrors how controller-runtime's own `builder.For()` supports unstructured types).
- Controller setup:
  - `mgr := mcmanager.New(hubRestConfig, provider, opts)` where `provider` is `cluster-inventory-api`'s provider pointed at `hub`'s ClusterProfiles (from Phase 3) — note the provider here is used only for **outbound** lookups (`mgr.GetCluster(ctx, "us")`), the controller's own watch stays on `hub`.
  - Reconciler logic: on `RegionalWidgetRequest` create/update, read `.spec.region`; `cl, err := mgr.GetCluster(ctx, mcmanager.ClusterName(region))`; using `cl.GetClient()`, upsert a `Widget` (Phase 2's CRD; use its generated Go types since it's ours to define — no need for unstructured here) named after the request, carrying `.spec.message` through.
  - Status propagation: watch `Widget` status on `us` (a **second**, spoke-side watch — this is the point where multicluster-runtime's normal multi-cluster fan-out is actually used, as opposed to Phase 5's hub-only watch) and copy `{region, phase, endpoint}` into `RegionalWidgetRequest.status` on hub, which Kro/owner-reference bubbles up to `GlobalWidget.status`.
- Files produced: `platform-mvp/binding-controller/main.go`, `platform-mvp/binding-controller/controller.go`, `platform-mvp/binding-controller/go.mod`
- Acceptance: with Phases 1–4 up, running the binding controller and then applying a `GlobalWidget{regions:[us]}` on `hub` results in a real `Widget` on `us` and `GlobalWidget.status.regions[0].phase == Ready` / `.endpoint` populated on `hub`.

## Phase 6 — E2E verification (`06-e2e-verification.md`)

**Goal**: prove the full loop end to end, scripted and repeatable.

- `hack/platform-mvp/e2e.sh`: creates clusters (Phase 1) → installs the widget operator (Phase 2) → registers fleet (Phase 3) → installs Kro RGD (Phase 4) → runs binding controller (Phase 5) → applies a sample `GlobalWidget` → polls `GlobalWidget.status` until every region reports `phase: Ready` → asserts `status.regions[0].endpoint` is non-empty.
- Acceptance: script exits 0; document manual teardown (`hack/platform-mvp/destroy-clusters.sh`).

## Phase 99 — Extending to EU/ASIA (`99-extending-to-eu-asia.md`, design-only)

Document, without implementing: repeat Phase 1 (new kind cluster) + Phase 2 (widget operator in it) + Phase 3 (new ClusterProfile) per region; Phase 4's RGD already supports arbitrary region lists; Phase 5's binding controller already does `mgr.GetCluster(ctx, ClusterName(region))` generically — no code change needed there, only fleet registration growth. Because the spoke payload is now a trivial operator rather than a stateful Ceph cluster, standing up additional regions is cheap (no per-region resource-budget concern to call out).

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

## Addendum — Rook/Ceph-on-kind abandoned, replaced with widget operator (2026-07-10)

Spent a multi-hour live session trying to repair the `us` cluster's Rook/Ceph deployment (which had 0 OSDs) and root-caused a chain of environment issues, each real and each fixed in turn, before hitting a wall that isn't fixable from this repo:

1. Host `fs.inotify.max_user_instances=128` (too low for two multi-pod kind clusters) was crash-looping `kube-proxy`/coredns/CSI plugins cluster-wide. Fixed: raised to 512, persisted via `/etc/sysctl.d/99-kind-inotify.conf`.
2. The `us-worker` node's loop-device attachment (`losetup`) doesn't survive a Docker container restart (host rebooted, container restarted, backing file `/var/lib/rook-loopfile` survived but its loop attachment didn't) — a standing fragility of the loop-device-in-kind pattern called out as a known risk in this plan's original Phase 2.
3. Rook's own device inventory hardcodes loop devices as `unsupported diskType loop` regardless of `deviceFilter` config (confirmed via [rook/rook#7206](https://github.com/rook/rook/issues/7206), open since 2021, no plan to fix) — worked around by moving OSDs to a PVC-backed `storageClassDeviceSet` against a static Local PV, bypassing Rook's host-device scan entirely.
4. That hit a deeper wall: Kubernetes' in-tree `local` volume plugin's block-mode mapping (`pkg/volume/util/volumepathhandler`, `AttachFileDevice`/`getLoopDeviceFromSysfs`) is only designed to take a **regular file** as `PersistentVolume.spec.local.path` and loop-mount it itself — it has no code path for adopting an already-attached loop device, so pointing `local.path` straight at `/dev/loopN` fails deterministically (confirmed identical failure on both `kindest/node:v1.30.0` and `v1.35.1`, ruling out a version regression). Once understood, the actual fix was to point `local.path` at the backing file itself and let kubelet manage the loop-mount — but by that point the storage stack had grown to: sysctl tuning + loop-file lifecycle + a static Local PV/StorageClass + PVC-based `storageClassDeviceSets` + Rook operator/cluster Helm releases, all to stand up a single-OSD toy cluster.

None of that machinery has anything to do with what this MVP exists to prove — the Kro + multicluster-runtime placement/status-propagation pattern. Rook was originally chosen to make the demo's downstream payload feel "real," but "real" here means "an unrelated distributed storage system fighting Docker-in-Docker," not "a meaningful test of the pattern." Decision: replace Phase 2 with a minimal `Widget` CRD + operator that only flips status fields (see Phase 2, above). This removes the entire loop-device/kubelet/Rook failure domain while preserving every other phase's structure and the actual thing under test. The Rook chart/values/PV-template work done during this session (`deploy/platform-mvp/chart/us/`, `deploy/platform-mvp/rook/local-pv.yaml.tmpl`, `hack/platform-mvp/attach-loop-devices.sh`) is left in place as a working reference for whoever later wants a real Rook backend on real hardware — it is not deleted, just no longer on the MVP's critical path.

## Upstream references (pin exact versions when implementing — do not float `master`/`latest`)

- **Kro**: https://kro.run/docs/overview/ · RGD concept: https://kro.run/docs/concepts/rgd/overview/ · source: https://github.com/kubernetes-sigs/kro · install via Helm chart published from that repo's releases (pick latest tagged, e.g. check `https://github.com/kubernetes-sigs/kro/releases` at implementation time).
- **cluster-inventory-api** (`ClusterProfile` CRD): https://github.com/kubernetes-sigs/cluster-inventory-api
- **multicluster-runtime** (this repo): provider used is `providers/cluster-inventory-api/provider.go`; pattern for Secret+ClusterProfile wiring to copy/adapt is `examples/cluster-inventory-api/setup-kind-demo.sh` and `examples/cluster-inventory-api/e2e-incluster.sh`; core interfaces this plan relies on are `pkg/multicluster/multicluster.go` (`Provider`, `Aware`) and `pkg/manager/manager.go` (`Manager.GetCluster`).
- **kind**: multi-cluster-on-shared-Docker-network behavior and `--internal` kubeconfig flag: https://kind.sigs.k8s.io/docs/user/configuration/ and `kind get kubeconfig --help`.

## Verification (overall)

Since this is a from-scratch build with no existing tests to run: each phase's own acceptance criteria (above) is the test for that phase. The Phase 6 e2e script is the end-to-end proof the whole plan is required to produce. No phase should be marked done without its acceptance criteria demonstrated live against real kind clusters — this is infrastructure, not something a unit test can substitute for.
