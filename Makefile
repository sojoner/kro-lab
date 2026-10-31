# Platform MVP Makefile
# Umbrella Helm charts + Flux CD + Chainsaw E2E
#
# Quick start:
#   make deploy        → build images, load them into kind, deploy everything (no registry needed)
#   make grafana       → port-forward Grafana to localhost:3000
#   make validate      → run Chainsaw E2E tests
#   make clean         → destroy everything
#
SHELL := /usr/bin/env bash

export PATH := $(shell go env GOPATH)/bin:$(PATH)

# ── Externalized config ──────────────────────────────────────────────────────
KIND_HUB          ?= hub
# Rendered from KIND_SPOKE_CONFIG_TMPL_hub (same mechanism as the spokes: render-kind-config-<name>).
KIND_HUB_CONFIG   ?= $(KIND_RENDER_DIR)/kind-$(KIND_HUB).yaml
KIND_NODE_IMAGE_hub ?= kindest/node:v1.35.1
KIND_SPOKE_CONFIG_TMPL_hub ?= deploy/platform-mvp/kind/kind-hub.yaml.tmpl

# Spoke clusters (kind cluster name == spoke name == ClusterProfile name ==
# chart/spoke/values-<name>.yaml). Adding a spoke = one entry here plus a
# KIND_NODE_IMAGE_<name>, a values file, and a hub-services fleet entry.
SPOKES            ?= us eu eu-storage
# KubeVirt 1.9 supports Kubernetes 1.34-1.36 only: every KUBEVIRT_SPOKES entry needs such an image.
KIND_NODE_IMAGE_us ?= kindest/node:v1.35.1
KIND_NODE_IMAGE_eu ?= kindest/node:v1.35.1
KIND_NODE_IMAGE_eu-storage ?= kindest/node:v1.35.1
KIND_SPOKE_CONFIG_TMPL ?= deploy/platform-mvp/kind/kind-spoke.yaml.tmpl
# Spokes hosting a Ceph OSD get a template that also mounts the host udev db.
KIND_SPOKE_CONFIG_TMPL_eu-storage ?= deploy/platform-mvp/kind/kind-spoke-storage.yaml.tmpl
HOST_UDEV_DIR     ?= /run/udev
KIND_RENDER_DIR   ?= deploy/platform-mvp/kind/rendered
SPOKE_API_PORT    ?= 6443
# Per-spoke apiserver auth dir, mounted into the spoke's control plane.
# Readable/writable by the invoking user (no root-owned /tmp race, survives
# host reboots) — always resolved relative to KIND_SPOKE_CONFIG_TMPL's own
# location, never a machine-specific absolute path. Spoke X uses X-auth/.
SPOKE_AUTH_BASE   ?= $(abspath $(dir $(KIND_SPOKE_CONFIG_TMPL)))

INFRA_CHART        ?= deploy/platform-mvp/chart/infrastructure
SPOKE_CHART        ?= deploy/platform-mvp/chart/spoke
CRDS_CHART         ?= deploy/platform-mvp/chart/crds
HUBSVC_CHART       ?= deploy/platform-mvp/chart/hub-services
# Helm release name and namespace of each hub chart. Flux's HelmReleases must carry the same, or it builds a
# second copy instead of adopting what make deploy installs (check-flux-releases). Service and deployment
# names derive from the release name (hub-grafana, ...), so the names are not free settings.
CRDS_RELEASE       ?= crds
CRDS_NS            ?= default
INFRA_RELEASE      ?= hub
HUBSVC_RELEASE     ?= hub-services
HUBSVC_NS          ?= default
MGMT_RELEASE       ?= management-plane
CHARTS_DIR         ?= deploy/platform-mvp/chart
FLUX_KS_NAME       ?= platform
HELM_TIMEOUT       ?= 15m

INGRESS_HOST       ?= bm4080.taildf7067.ts.net
# Dex's issuer URL: what Dex stamps into tokens and what every API server trusts.
DEX_ISSUER         ?= https://$(INGRESS_HOST)/dex
GRAFANA_URL        ?= https://$(INGRESS_HOST)
GRAFANA_PF_PORT    ?= 3000
OBS_NS             ?= monitoring

SPOKE_KC_DIR       ?= hack/platform-mvp
# Tenants and workload identity shared by the spoke and hub-services charts.
TENANTS_FILE       ?= deploy/platform-mvp/tenants.yaml
FLUX_HUB_RELEASE   ?= deploy/platform-mvp/flux/hub-helmrelease.yaml

CHAINSAW_DIR       ?= tests/e2e
CHAINSAW_REPORT    ?= chainsaw-report.json
CHAINSAW_RUNNER_DIR ?= deploy/platform-mvp/observability

DOCKER_REGISTRY    ?= sojoner
IMAGE_TAG          ?= dev
OV_DIR             ?= platform-mvp/oidc-verifier
VMBC_DIR           ?= platform-mvp/vm-binding-controller
BBC_DIR            ?= platform-mvp/bucket-binding-controller
# Go modules besides the root one; every test/lint/race target loops over these.
GO_MODULES         ?= $(OV_DIR) $(VMBC_DIR) $(BBC_DIR)

OV_IMAGE           ?= $(DOCKER_REGISTRY)/oidc-verifier:$(IMAGE_TAG)
VMBC_IMAGE         ?= $(DOCKER_REGISTRY)/vm-binding-controller:$(IMAGE_TAG)
BBC_IMAGE          ?= $(DOCKER_REGISTRY)/bucket-binding-controller:$(IMAGE_TAG)

CRDS_DIR           ?= deploy/platform-mvp/crds
OUT_DIR            ?= bin
VMBC_BIN           ?= $(OUT_DIR)/vm-binding-controller
BBC_BIN            ?= $(OUT_DIR)/bucket-binding-controller
FLUX_DIR           ?= deploy/platform-mvp/flux
CERT_MANAGER_VERSION ?= v1.17.1
CHAINSAW_VERSION   ?= v0.2.15
KUBELOGIN_VERSION  ?= v1.36.4

# People log in with kubectl: make tenant-kubeconfigs writes one kubeconfig per tenant, a context per
# cluster in the tenant's namespace, and a Dex login through kubectl oidc-login (kubelogin). The
# keyboard flow prints a URL and takes the code back, so it works over SSH too.
TENANT_KUBECONFIG_DIR ?= hack/platform-mvp
DEX_CLIENT_ID      ?= kubernetes
OIDC_LOGIN_GRANT   ?= authcode-keyboard
# The keyboard flow's redirect: Dex shows the code to paste (listed in dex.kubernetesClient.redirectURIs).
OIDC_LOGIN_REDIRECT ?= urn:ietf:wg:oauth:2.0:oob
OIDC_LOGIN_SCOPES  ?= email groups

# The management plane: the metrics-operator's CRDs are fetched like the other upstream manifests
# (wave 1, crds chart); its chart is a dependency of MGMT_CHART (released into OBS_NS).
METRICS_OPERATOR_VERSION ?= v1.2.2
METRICS_CRDS_URL   ?= https://raw.githubusercontent.com/openmcp-project/metrics-operator/$(METRICS_OPERATOR_VERSION)/cmd/metrics-operator/embedded/crds
METRICS_CRDS_KINDS ?= datasinks federatedclusteraccesses federatedmanagedmetrics federatedmetrics managedmetrics metrics remoteclusteraccesses
MGMT_CHART         ?= deploy/platform-mvp/chart/management-plane

# KubeVirt runs only on these spokes (needs /dev/kvm on the host). Its operator
# manifest is cached under CRDS_DIR like the other upstream manifests.
KUBEVIRT_VERSION   ?= v1.9.1
KUBEVIRT_SPOKES    ?= eu us

# Rook/Ceph (S3 via RADOS Gateway) runs on these spokes. Each gets a loop-device
# OSD created inside its worker node (privileged kind node, no host sudo).
ROOK_VERSION       ?= 1.21.1
ROOK_REPO          ?= https://charts.rook.io/release
ROOK_NS            ?= rook-ceph
ROOK_DIR           ?= deploy/platform-mvp/rook
ROOK_SPOKES        ?= eu-storage
# The RADOS Gateway's NodePort, published on the host at the same port (kind-spoke-storage.yaml.tmpl).
S3_NODE_PORT       ?= 30080
CEPH_LOOP_SIZE     ?= 20G
CEPH_LOOP_IMG      ?= /var/lib/ceph-osd.img
ROOK_TIMEOUT       ?= 10m

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Platform MVP — build, deploy, validate"
	@echo ""
	@echo "Deploy (4-wave Helm chart decomposition):"
	@echo "  make deploy        Full deployment (clusters + 4 waves + the management plane)"
	@echo "  make deploy-wave1  Wave 1: Install all CRDs on hub + spokes"
	@echo "  make deploy-wave2  Wave 2: Infrastructure on hub (LGTM + Dex + ingress)"
	@echo "  make deploy-wave3  Wave 3: Hub services (Kro + VM/bucket binding controllers + fleet)"
	@echo "  make deploy-wave4  Wave 4: Spokes (oidc-verifier + tenant RBAC; KubeVirt on KUBEVIRT_SPOKES, Rook/Ceph on ROOK_SPOKES)"
	@echo "  make deploy-rook   Rook/Ceph + RADOS Gateway on ROOK_SPOKES (also part of wave 4)"
	@echo "  make deploy-management-plane  Metrics-operator + intent measurement on hub (after wave 3)"
	@echo "  make deploy-cd     Enable GitOps (Flux CD) on hub"
	@echo "  make clusters      Create kind clusters"
	@echo ""
	@echo "Test:"
	@echo "  make test          Run all Go unit tests (root + GO_MODULES)"
	@echo "  make test-race     Unit tests with race detector"
	@echo "  make test-cover    Unit tests with coverage profiles"
	@echo "  make validate      Run the full Chainsaw E2E suite"
	@echo "  make lint          retired-reference guard + go vet + gofmt check"
	@echo "  make check-retired Fail if the retired demo payload is referenced again"
	@echo "  make lint-fix      Auto-fix formatting + go vet"
	@echo ""
	@echo "Build:"
	@echo "  make build         Build the controller binaries into $(OUT_DIR)/"
	@echo "  make build-images  Build all Docker images"
	@echo "  make load-images   Load the images into the kind clusters (part of make deploy)"
	@echo "  make push-images   Optional: push the images to $(DOCKER_REGISTRY)"
	@echo ""
	@echo "Observe:"
	@echo "  make grafana       Port-forward Grafana → localhost:3000"
	@echo "  make grafana-url   Print dashboard URLs"
	@echo ""
	@echo "Clean:"
	@echo "  make clean         Destroy clusters + artifacts"
	@echo "  make clean-artifacts  Remove bin/ and coverage files"
	@echo ""
	@echo "Tools:"
	@echo "  make install-chainsaw   Install Chainsaw CLI"
	@echo "  make install-flux       Install Flux CLI"
	@echo "  make chainsaw-runner    Build in-cluster Chainsaw runner"
	@echo "  make verify-all         Full clean-room: clean → deploy → validate → deploy-cd"

# ── Test ─────────────────────────────────────────────────────────────────────
.PHONY: test test-root test-ov test-vmbc test-bbc test-race test-cover
test: test-root test-ov test-vmbc test-bbc
	@echo "==> All unit tests passed"

test-root:
	go test ./... -count=1

test-ov:
	cd $(OV_DIR) && go test ./... -count=1

test-vmbc:
	cd $(VMBC_DIR) && go test ./... -count=1

test-bbc:
	cd $(BBC_DIR) && go test ./... -count=1

test-race:
	go test -race ./... -count=1
	@for d in $(GO_MODULES); do (cd $$d && go test -race ./... -count=1) || exit 1; done

test-cover:
	go test -coverprofile=coverage-root.out ./...
	cd $(VMBC_DIR) && go test -coverprofile=../../coverage-vmbc.out ./...
	cd $(BBC_DIR) && go test -coverprofile=../../coverage-bbc.out ./...
	@echo "Coverage: coverage-*.out"

# ── Lint ─────────────────────────────────────────────────────────────────────
.PHONY: lint lint-fix check-retired check-runner-tests check-tests check-test-reference check-flux-releases check-flux-build check-deploy-order check-tenants check-tenant-charts check-portal-trust check-guardrails check-docs check-service-hosts
# The demo payload the Bucket service replaced must not come back into code,
# charts, tests or docs. The [w] keeps the pattern from matching its own line.
# Tracked and new files only, so generated reports are ignored.
RETIRED_PATHS ?= deploy platform-mvp tests hack providers Makefile README.md docs
check-retired:
	@echo "==> checking for retired demo-payload references"
	@if git grep -iIlE --untracked '[w]idget' -- $(RETIRED_PATHS); then \
		echo "ERROR: retired demo-payload references remain (files above)"; \
		exit 1; \
	fi

# Every test the in-cluster runner is told to run must exist (a renumbering would otherwise
# only show up as a failing CronJob).
RUNNER_TESTS_VALUES ?= deploy/platform-mvp/chart/infrastructure/values.yaml
check-runner-tests:
	@echo "==> checking the in-cluster runner's test list"
	@missing=0; for t in $$(sed -n '/^cronjob:/,/^[a-z]/p' $(RUNNER_TESTS_VALUES) | sed -n 's/^    - \(.*\)$$/\1/p'); do \
		[ -d "$(CHAINSAW_DIR)/tests/$$t" ] || { echo "ERROR: cronjob.tests entry '$$t' is not a directory under $(CHAINSAW_DIR)/tests"; missing=1; }; \
	done; [ $$missing = 0 ]

# Tests are numbered 01..N without gaps, a test's name is its directory without the number, and
# every test opts out of concurrency: chainsaw runs concurrent tests in no fixed order, and later
# tests rely on the state earlier ones leave.
check-tests:
	@echo "==> checking e2e test numbering, names and order"
	@bad=0; n=0; for d in $(CHAINSAW_DIR)/tests/*/; do \
		n=$$((n+1)); base=$$(basename $$d); want=$$(printf %02d $$n); f=$$d/chainsaw-test.yaml; \
		[ "$${base%%-*}" = "$$want" ] || { echo "ERROR: $$base: expected number $$want"; bad=1; }; \
		grep -qx "  name: $${base#*-}" $$f || { echo "ERROR: $$base: metadata.name must be $${base#*-}"; bad=1; }; \
		grep -qx '  concurrent: false' $$f || { echo "ERROR: $$base: spec.concurrent must be false"; bad=1; }; \
	done; [ $$bad = 0 ]

# The Chainsaw Results dashboard carries a hand-written table of the suite; it must list every test
# and say how many there are and how many the in-cluster runner executes.
RESULTS_DASHBOARD ?= $(INFRA_CHART)/dashboards/chainsaw-results.json
check-test-reference:
	@echo "==> checking that the Chainsaw Results dashboard lists every test"
	@bad=0; n=0; for d in $(CHAINSAW_DIR)/tests/*/; do \
		n=$$((n+1)); base=$$(basename $$d); \
		grep -qF "| $${base%%-*} | $${base#*-} |" $(RESULTS_DASHBOARD) || { echo "ERROR: $$base is missing in $(RESULTS_DASHBOARD)"; bad=1; }; \
	done; \
	grep -qF "**Total: $$n test cases**" $(RESULTS_DASHBOARD) || { echo "ERROR: the total in $(RESULTS_DASHBOARD) is not $$n"; bad=1; }; \
	r=$$(sed -n '/^cronjob:/,/^[a-z]/p' $(RUNNER_TESTS_VALUES) | grep -c '^    - '); \
	grep -qF "runs $$r of them" $(RESULTS_DASHBOARD) || { echo "ERROR: $(RESULTS_DASHBOARD) does not say that the CronJob runs $$r"; bad=1; }; \
	[ $$bad = 0 ]

# Flux takes over the hub's Helm releases (deploy-cd), so it needs one for every hub chart (the spoke
# chart is not on the hub, and tenants apply the tenant chart themselves), and a release can only
# wait for releases that exist.
# Release identity (name, namespace, chart) of every hub chart as make deploy installs it.
HUB_RELEASES ?= $(CRDS_RELEASE):$(CRDS_NS):crds $(INFRA_RELEASE):$(OBS_NS):infrastructure $(HUBSVC_RELEASE):$(HUBSVC_NS):hub-services $(MGMT_RELEASE):$(OBS_NS):management-plane
check-flux-releases:
	@echo "==> checking that Flux adopts exactly the Helm releases make deploy installs"
	@python3 -I -c 'import os, sys, yaml; \
	f, d = sys.argv[1], sys.argv[2]; \
	want = {c: (r, ns) for r, ns, c in (a.split(":") for a in sys.argv[3:])}; \
	hub = sorted(set(os.listdir(d)) - {"spoke", "tenant"}); \
	rels = [x for x in yaml.safe_load_all(open(f)) if x and x.get("kind") == "HelmRelease"]; \
	by = {os.path.basename(r["spec"]["chart"]["spec"]["chart"]): r for r in rels}; \
	names = {r["metadata"]["name"] for r in rels}; \
	ident = lambda r: (r["spec"].get("releaseName", r["metadata"]["name"]), r["spec"].get("storageNamespace", r["metadata"]["namespace"]), r["spec"].get("targetNamespace", r["metadata"]["namespace"])); \
	errs = ["chart " + c + " has no release identity in the Makefile" for c in hub if c not in want] \
	  + ["no HelmRelease for chart " + c for c in want if c not in by] \
	  + ["HelmRelease of unknown chart " + c for c in by if c not in want] \
	  + ["%s: Flux installs release %s in %s (stored in %s), make deploy installs %s in %s" % (c, ident(r)[0], ident(r)[2], ident(r)[1], want[c][0], want[c][1]) for c, r in by.items() if c in want and ident(r) != (want[c][0], want[c][1], want[c][1])] \
	  + ["%s: valuesFiles must be %s, as make deploy passes -f e2e-values.yaml (source-controller resolves them from the repository root, not the chart directory)" % (c, [os.path.normpath(r["spec"]["chart"]["spec"]["chart"]) + "/" + v for v in ("values.yaml", "e2e-values.yaml")]) for c, r in by.items() if os.path.exists(os.path.join(d, c, "e2e-values.yaml")) and r["spec"]["chart"]["spec"].get("valuesFiles") != [os.path.normpath(r["spec"]["chart"]["spec"]["chart"]) + "/" + v for v in ("values.yaml", "e2e-values.yaml")]] \
	  + ["%s waits for %s, which is not a HelmRelease" % (r["metadata"]["name"], x["name"]) for r in rels for x in r["spec"].get("dependsOn", []) if x["name"] not in names]; \
	sys.exit("ERROR: " + "; ".join(errs) if errs else 0)' $(FLUX_HUB_RELEASE) $(CHARTS_DIR) $(HUB_RELEASES)

# kubectl accepts a malformed manifest that Flux's Kustomization rejects (BuildFailed, nothing applied), and
# kubectl apply of the release files would skip the Kustomization's ${placeholder} substitution. Build as Flux does.
check-flux-build:
	@echo "==> checking that Flux can build $(FLUX_DIR) and fills every placeholder"
	@if ! command -v flux >/dev/null 2>&1; then echo "  (flux CLI not installed: skipped)"; exit 0; fi; \
	T=$$(mktemp -d); trap 'rm -rf $$T' EXIT; \
	python3 -I -c 'import sys, yaml; print(yaml.safe_dump(next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Kustomization")))' $(FLUX_DIR)/bootstrap/flux-setup.yaml > $$T/ks.yaml; \
	flux build kustomization $(FLUX_KS_NAME) --path $(FLUX_DIR) --kustomization-file $$T/ks.yaml --dry-run > $$T/out.yaml || { echo "ERROR: flux cannot build $(FLUX_DIR)"; exit 1; }; \
	[ -s $$T/out.yaml ] || { echo "ERROR: the build of $(FLUX_DIR) is empty"; exit 1; }; \
	if grep -q '\$${' $$T/out.yaml; then echo "ERROR: a placeholder is left after the build"; exit 1; fi; \
	if grep -qE '^[[:space:]]+host:[[:space:]]*(""|null)?$$' $$T/out.yaml; then echo "ERROR: a release got an empty ingress host (an undefined substitution variable becomes null)"; exit 1; fi
	@if grep -nE 'apply -f \$$\(FLUX_DIR\)/?[[:space:]]*$$' Makefile; then echo "ERROR: deploy-flux must apply only the bootstrap; the Kustomization applies the rest with its substitutions"; exit 1; fi

# Test 32 runs in the in-cluster runner and needs the management plane, so a fresh deploy must install
# it after wave 3 (it measures the intents) and before the runner starts.
check-deploy-order:
	@echo "==> checking that make deploy installs the management plane after wave 3 and before the runner"
	@awk '/^deploy:/ {on=1; next} on && /^[^\t]/ {exit} on && /deploy-wave3/ {a=NR} on && /deploy-management-plane/ {b=NR} on && /chainsaw-runner/ {c=NR} \
	END {if (!(a && b && c && a < b && b < c)) {print "ERROR: deploy must run deploy-wave3, then deploy-management-plane, then chainsaw-runner"; exit 1}}' Makefile

# Every example tenant's chart renders and orders for its own tenant (chart/tenant/values-<tenant>.yaml).
TENANT_CHART ?= $(CHARTS_DIR)/tenant
check-tenant-charts:
	@echo "==> checking the tenant charts against $(TENANTS_FILE)"
	@for f in $(TENANT_CHART)/values-*.yaml; do \
		t=$$(basename $$f .yaml); t=$${t#values-}; \
		python3 -I -c 'import sys, yaml; sys.exit(0 if sys.argv[1] in [t["id"] for t in yaml.safe_load(open(sys.argv[2]))["tenants"]] else "ERROR: " + sys.argv[1] + " is not a tenant in " + sys.argv[2])' $$t $(TENANTS_FILE) || exit 1; \
		helm template $$t $(TENANT_CHART) -f $$f --set sshPublicKey=ssh-rsa-placeholder | python3 -I -c 'import sys, yaml; \
		ns = {d["metadata"]["namespace"] for d in yaml.safe_load_all(sys.stdin) if d}; \
		sys.exit(0 if ns == {sys.argv[1]} else "ERROR: %s orders into %s" % (sys.argv[2], sorted(ns)))' $$t $$f || exit 1; \
	done

# Flux cannot read tenants.yaml, so its hub-services release carries a copy; they must not drift.
check-tenants:
	@echo "==> checking the Flux tenants copy against $(TENANTS_FILE)"
	@python3 -I -c 'import sys, yaml; \
	src = yaml.safe_load(open(sys.argv[1])); \
	docs = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d.get("metadata", {}).get("name") == "hub-services"]; \
	copy = docs[0]["spec"]["values"]; \
	ok = all(copy.get(k) == src.get(k) for k in ("tenants", "workloadIdentity")); \
	sys.exit(0 if ok else "ERROR: tenants/workloadIdentity in " + sys.argv[2] + " differ from " + sys.argv[1])' $(TENANTS_FILE) $(FLUX_HUB_RELEASE)

# The portal's name lives in three charts: the Dex client (infrastructure), the audience the hub
# trusts (hub-auth-values.yaml) and the client id Headlamp logs in with (management-plane); its path
# lives in the ingress and in Headlamp's base URL. A mismatch only shows as a failed login.
PORTAL_VALUES ?= $(INFRA_CHART)/values.yaml $(HUB_AUTH_VALUES) $(MGMT_CHART)/values.yaml
check-portal-trust:
	@echo "==> checking that the portal uses Dex's one client, which the hub trusts, and its paths agree"
	@python3 -I -c 'import sys, yaml; \
	infra, hub, mgmt = [yaml.safe_load(open(f)) for f in sys.argv[1:4]]; \
	oidc = mgmt["portal"]["oidc"]; hl = mgmt["headlamp"]["config"]; base = hl["baseURL"]; \
	client = infra["dex"]["kubernetesClient"]; \
	auds = hub["authConfiguration"]["dexIssuer"]["audiences"]; \
	errs = []; \
	oidc["clientID"] == client["id"] or errs.append("portal client id %s is not Dex client %s" % (oidc["clientID"], client["id"])); \
	auds == [client["id"]] or errs.append("the hub trusts audiences %s, want only %s" % (auds, client["id"])); \
	oidc["secretName"] == hl["oidc"]["externalSecret"]["name"] or errs.append("portal.oidc.secretName differs from the Headlamp externalSecret name"); \
	mgmt["ingress"]["path"] == base or errs.append("ingress.path %s differs from headlamp baseURL %s" % (mgmt["ingress"]["path"], base)); \
	(base + "/oidc-callback") in client["redirectPaths"] or errs.append("Dex client %s has no redirect path %s/oidc-callback" % (client["id"], base)); \
	sys.exit("ERROR: " + "; ".join(errs) if errs else 0)' $(PORTAL_VALUES)

# additionalProtectedNamespaces must widen the namespace selector of protect-system-namespaces;
# repeating its validation would leave the extra namespaces unprotected.
check-guardrails:
	@echo "==> checking that extra protected namespaces reach the policy's namespaceSelector"
	@helm template x $(SPOKE_CHART) -f $(SPOKE_CHART)/values-us.yaml -f $(TENANTS_FILE) --set authConfiguration.dexIssuer.url=$(DEX_ISSUER) \
		--show-only templates/admission-guardrails.yaml --set 'admissionPolicies.additionalProtectedNamespaces={extra-ns}' | python3 -I -c 'import sys, yaml; \
	p = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == "protect-system-namespaces"][0]["spec"]; \
	values = p["matchConstraints"]["namespaceSelector"]["matchExpressions"][0]["values"]; \
	sys.exit(0 if "extra-ns" in values and len(p["validations"]) == 1 else "ERROR: additionalProtectedNamespaces do not reach the namespaceSelector (values=%s, validations=%d)" % (values, len(p["validations"])))'

# The docs stay short and show what they claim: every relative link and anchor resolves, every
# document but the index has a mermaid diagram and a code block, none exceeds the word budget,
# and the reading list (books, papers) lives in the index only.
DOCS_DIR ?= docs/platform-mvp
DOCS_INDEX ?= $(DOCS_DIR)/README.md
DOCS_MAX_WORDS ?= 1500
DOCS_READING_HOSTS ?= leanpub.com packtpub.com github.com/PacktPublishing tag-app-delivery.cncf.io teamtopologies.com max-koerbaecher-io-media
define CHECK_DOCS_PY
import glob, os, re, sys
index, budget, hosts = sys.argv[1], int(sys.argv[2]), sys.argv[3].split()
docs = sorted(glob.glob(os.path.join(os.path.dirname(index), "*.md")))
errs = []
def strip(text):  # drop fenced code, so its "#" lines and "](" are not headings or links
    return re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
def anchors(f):
    heads = re.findall(r"^#{1,6} (.+)$$", strip(open(f).read()), re.M)
    return {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-") for h in heads}
for f in docs + ["README.md"]:
    text = open(f).read()
    for target in re.findall(r"\]\(([^)\s]+)\)", strip(text)):
        if re.match(r"[a-z]+:", target):
            continue
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if not os.path.exists(dest):
            errs.append("%s: broken link %s" % (f, target))
        elif frag and dest.endswith(".md") and frag not in anchors(dest):
            errs.append("%s: missing anchor %s" % (f, target))
    if f in (index, "README.md"):
        continue
    if "```mermaid" not in text:
        errs.append("%s: no mermaid diagram" % f)
    if not re.search(r"^```(?!mermaid)\w+", text, re.M):
        errs.append("%s: no code block" % f)
    words = len(strip(text).split())
    if words > budget:
        errs.append("%s: %d words, budget %d" % (f, words, budget))
    errs += ["%s: reading-list link %s outside the index" % (f, h) for h in hosts if h in text]
sys.exit("ERROR:\n  " + "\n  ".join(errs) if errs else 0)
endef
export CHECK_DOCS_PY
check-docs:
	@echo "==> checking docs: links, diagrams, code, word budget, reading list"
	@python3 -I -c "$$CHECK_DOCS_PY" $(DOCS_INDEX) $(DOCS_MAX_WORDS) "$(DOCS_READING_HOSTS)"

# A spoke hosts a service in four places that must agree: the Makefile's host list (which installs
# the software), the spoke chart's switches (RBAC, tenant roles), the fleet labels the controller's
# clusterSelector engages, and the controller's projected token with the spoke's audience.
# Arguments after the files: controller, its host list, its spoke switches; once per service.
define CHECK_SERVICE_HOSTS_PY
import sys, yaml
chart, hub_file, spokes, args = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4:]
hub = yaml.safe_load(open(hub_file))
defaults = yaml.safe_load(open(chart + "/values.yaml"))
labels = {c["name"]: c.get("labels") or {} for c in hub["fleet"]["clusters"]}
errs = []
for i in range(0, len(args), 3):
    ctl, hosts, switches = args[i], args[i + 1].split(), args[i + 2].split(",")
    sel = dict(kv.split("=", 1) for kv in hub[ctl]["clusterSelector"].split(",") if kv)
    tokens = {t["serviceAccountToken"]["path"]: t["serviceAccountToken"]["audience"] for t in hub[ctl]["spokeTokens"]}
    unknown = sorted(set(hosts) - set(spokes)) + sorted(p for p in tokens if p.removesuffix("-token") not in spokes)
    if unknown:
        errs.append("%s names spokes that are not in SPOKES: %s" % (ctl, ", ".join(unknown)))
    for s in spokes:
        own = yaml.safe_load(open("%s/values-%s.yaml" % (chart, s))) or {}
        aud = (own.get("authConfiguration") or {}).get("hubIssuer", {}).get("audience")
        says = {"in the Makefile host list": s in hosts}
        for k in switches:
            says["%s.enabled in values-%s.yaml" % (k, s)] = (own.get(k) or {}).get("enabled", defaults[k]["enabled"])
        says["fleet labels %s" % sel] = all(labels.get(s, {}).get(k) == v for k, v in sel.items())
        says["%s.spokeTokens has %s-token for audience %s" % (ctl, s, aud)] = aud is not None and tokens.get(s + "-token") == aud
        if len(set(says.values())) > 1:
            errs.append("%s on %s: %s" % (ctl, s, "; ".join("%s: %s" % kv for kv in says.items())))
sys.exit("ERROR: spokes disagree about the services they host\n  " + "\n  ".join(errs) if errs else 0)
endef
export CHECK_SERVICE_HOSTS_PY
check-service-hosts:
	@echo "==> checking that Makefile, spoke values, fleet labels and controller tokens agree on service hosts"
	@python3 -I -c "$$CHECK_SERVICE_HOSTS_PY" $(SPOKE_CHART) $(HUBSVC_CHART)/values.yaml "$(SPOKES)" \
		vmBindingController "$(KUBEVIRT_SPOKES)" kubevirt,vmBindingControllerRBAC \
		bucketBindingController "$(ROOK_SPOKES)" objectStorage,bucketBindingControllerRBAC

lint: check-retired check-runner-tests check-tests check-test-reference check-flux-releases check-flux-build check-deploy-order check-tenants check-tenant-charts check-portal-trust check-guardrails check-docs check-service-hosts
	@echo "==> go vet + gofmt check"
	go vet ./...
	@for d in $(GO_MODULES); do (cd $$d && go vet ./...) || exit 1; done
	@if [ -n "$$(gofmt -l .)" ]; then \
		echo "ERROR: files not formatted:"; \
		gofmt -l .; \
		exit 1; \
	fi

lint-fix:
	gofmt -w .
	@for d in $(GO_MODULES); do (cd $$d && gofmt -w .) || exit 1; done
	go vet ./...
	@for d in $(GO_MODULES); do (cd $$d && go vet ./...) || exit 1; done

# ── Build ────────────────────────────────────────────────────────────────────
.PHONY: build build-vmbc build-bbc
build: build-vmbc build-bbc

build-vmbc:
	@mkdir -p $(OUT_DIR)
	cd $(VMBC_DIR) && go build -o ../../$(VMBC_BIN) .

build-bbc:
	@mkdir -p $(OUT_DIR)
	cd $(BBC_DIR) && go build -o ../../$(BBC_BIN) .

# ── Docker images (build only) ───────────────────────────────────────────────
.PHONY: build-images build-images-parallel build-ov-image build-vmbc-image build-bbc-image

build-images: build-ov-image build-vmbc-image build-bbc-image

build-ov-image:
	@echo "==> Building $(OV_IMAGE)"
	docker build -f $(OV_DIR)/Dockerfile -t $(OV_IMAGE) .

build-vmbc-image:
	@echo "==> Building $(VMBC_IMAGE)"
	docker build -f $(VMBC_DIR)/Dockerfile -t $(VMBC_IMAGE) .

build-bbc-image:
	@echo "==> Building $(BBC_IMAGE)"
	docker build -f $(BBC_DIR)/Dockerfile -t $(BBC_IMAGE) .

# Build all images in parallel
build-images-parallel:
	@echo "==> Building all images in parallel"
	$(MAKE) --no-print-directory build-ov-image & \
	$(MAKE) --no-print-directory build-vmbc-image & \
	$(MAKE) --no-print-directory build-bbc-image & \
	wait
	@echo "==> All images built"

# ── Load images into kind (what `make deploy` uses; no registry needed) ───────
# Controllers run on the hub; the OIDC verifier runs on every spoke. The charts use
# pullPolicy IfNotPresent, so a loaded image is never pulled. After rebuilding an image,
# `kubectl rollout restart` the Deployment to pick it up.
.PHONY: load-images
load-images:
	@echo "==> Loading images into kind"
	kind load docker-image $(VMBC_IMAGE) $(BBC_IMAGE) --name $(KIND_HUB)
	@for s in $(SPOKES); do kind load docker-image $(OV_IMAGE) --name $$s || exit 1; done

# ── Docker push (optional: share images through a registry) ──────────────────
.PHONY: push-images push-images-parallel push-ov push-vmbc push-bbc

push-images: push-ov push-vmbc push-bbc

push-ov:
	docker push $(OV_IMAGE)
push-vmbc:
	docker push $(VMBC_IMAGE)
push-bbc:
	docker push $(BBC_IMAGE)

push-images-parallel:
	@echo "==> Pushing all images to $(DOCKER_REGISTRY)"
	docker push $(OV_IMAGE) & \
	docker push $(VMBC_IMAGE) & \
	docker push $(BBC_IMAGE) & \
	wait
	@echo "==> All images pushed"

# ── CRD caching ──────────────────────────────────────────────────────────────
.PHONY: crds

crds: $(CRDS_DIR)/kro-core-install-manifests.yaml \
      $(CRDS_DIR)/clusterprofiles-crd.yaml \
      $(CRDS_DIR)/cert-manager.crds.yaml \
      $(CRDS_DIR)/prometheus-operator-crds.yaml \
      $(CRDS_DIR)/kubevirt-operator.yaml \
      $(CRDS_DIR)/metrics-operator-crds.yaml

$(CRDS_DIR):
	mkdir -p $(CRDS_DIR)

$(CRDS_DIR)/kro-core-install-manifests.yaml: | $(CRDS_DIR)
	curl -fsSL -o $@ https://github.com/kubernetes-sigs/kro/releases/download/v0.9.2/kro-core-install-manifests.yaml

$(CRDS_DIR)/clusterprofiles-crd.yaml: | $(CRDS_DIR)
	curl -fsSL -o $@ https://raw.githubusercontent.com/kubernetes-sigs/cluster-inventory-api/main/config/crd/bases/multicluster.x-k8s.io_clusterprofiles.yaml

$(CRDS_DIR)/cert-manager.crds.yaml: | $(CRDS_DIR)
	curl -fsSL -o $@ https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.crds.yaml

$(CRDS_DIR)/prometheus-operator-crds.yaml: | $(CRDS_DIR)
	curl -fsSL -o $@ https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.92.1/stripped-down-crds.yaml

$(CRDS_DIR)/kubevirt-operator.yaml: | $(CRDS_DIR)
	curl -fsSL -o $@ https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-operator.yaml

# One file for all seven kinds; the crds chart carries a byte-identical copy.
$(CRDS_DIR)/metrics-operator-crds.yaml: | $(CRDS_DIR)
	for k in $(METRICS_CRDS_KINDS); do echo '---'; curl -fsSL $(METRICS_CRDS_URL)/metrics.open-control-plane.io_$$k.yaml || exit 1; done > $@.tmp
	mv $@.tmp $@
	cp $@ $(CRDS_CHART)/templates/metrics-operator-crds.yaml

# ── Clusters ─────────────────────────────────────────────────────────────────
.PHONY: clusters ensure-spoke-auth-config

# Each spoke's kind config is generated from KIND_SPOKE_CONFIG_TMPL on every run
# so its extraMounts hostPath always points at that spoke's auth dir, resolved
# relative to the template's own location rather than hardcoded to one
# machine's checkout path.
render-kind-config-%:
	@mkdir -p "$(KIND_RENDER_DIR)" "$(SPOKE_AUTH_BASE)/$*-auth"
	@sed -e 's|__AUTH_DIR__|$(SPOKE_AUTH_BASE)/$*-auth|' \
		-e 's|__NODE_IMAGE__|$(KIND_NODE_IMAGE_$*)|' \
		-e 's|__UDEV_DIR__|$(HOST_UDEV_DIR)|' \
		-e 's|__S3_NODE_PORT__|$(S3_NODE_PORT)|' \
		-e 's|__SA_ISSUER__|https://$*-control-plane:$(SPOKE_API_PORT)|' \
		$(or $(KIND_SPOKE_CONFIG_TMPL_$*),$(KIND_SPOKE_CONFIG_TMPL)) > $(KIND_RENDER_DIR)/kind-$*.yaml

# Re-derive each spoke apiserver's AuthenticationConfiguration from the chart
# on every `make clusters` / `make deploy` / `make validate` run so a stale or
# missing file self-heals without a separate manual step. Content comes from
# chart/spoke/templates/auth-config.yaml + values-<spoke>.yaml via
# hack/platform-mvp/render-spoke-auth-config.sh — never hand-duplicate it
# here. Requires the hub cluster to already exist: the hub issuer's trust
# anchor is the hub apiserver's own CA (kind's cert isn't publicly trusted),
# extracted fresh each run rather than assumed stable.
# The Dex issuer's CA (the cert-manager self-signed cert backing the ingress,
# secret monitoring/ingress-tls) usually doesn't exist yet the first time this
# runs (before Wave 2) — included once it does. The apiserver hot-reloads
# this file, so a second `make ensure-spoke-auth-config` after Wave 2 (see
# `deploy`) picks it up without restarting anything.
ensure-spoke-auth-config: $(addprefix ensure-auth-config-,$(SPOKES))

ensure-auth-config-%: render-kind-config-%
	@mkdir -p "$(SPOKE_AUTH_BASE)/$*-auth" 2>/dev/null || { \
		echo "ERROR: cannot create $(SPOKE_AUTH_BASE)/$*-auth (likely root-owned after a host reboot)."; \
		exit 1; \
	}
	@docker exec $(KIND_HUB)-control-plane cat /etc/kubernetes/pki/ca.crt > "$(SPOKE_AUTH_BASE)/$*-auth/hub-ca.crt" || { \
		echo "ERROR: cannot read hub CA cert — is the hub cluster up? (kind get clusters)"; \
		exit 1; \
	}
	@kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) get secret ingress-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$(SPOKE_AUTH_BASE)/$*-auth/dex-ca.crt" || rm -f "$(SPOKE_AUTH_BASE)/$*-auth/dex-ca.crt"
	@DEX_CA=""; [ -s "$(SPOKE_AUTH_BASE)/$*-auth/dex-ca.crt" ] && DEX_CA="$(SPOKE_AUTH_BASE)/$*-auth/dex-ca.crt"; \
	./hack/platform-mvp/render-spoke-auth-config.sh $(SPOKE_CHART) $(SPOKE_CHART)/values-$*.yaml "$(SPOKE_AUTH_BASE)/$*-auth/hub-ca.crt" "$$DEX_CA" "$(DEX_ISSUER)" > "$(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml" 2>/dev/null || { \
		echo "ERROR: cannot write $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml (likely root-owned after a host reboot)."; \
		echo "  Run this once, then retry:"; \
		echo "  ./hack/platform-mvp/render-spoke-auth-config.sh $(SPOKE_CHART) $(SPOKE_CHART)/values-$*.yaml $(SPOKE_AUTH_BASE)/$*-auth/hub-ca.crt \"\" $(DEX_ISSUER) | sudo tee $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml > /dev/null"; \
		exit 1; \
	}
	@echo "  $* AuthenticationConfiguration ready at $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml"

# The hub trusts Dex like the spokes do. Its kube-apiserver reads the file at boot, but Dex's CA
# only exists after Wave 2: until then a placeholder without issuers keeps it booting, and the
# real file then replaces it (the API server hot-reloads it).
HUB_AUTH_DIR    ?= $(SPOKE_AUTH_BASE)/$(KIND_HUB)-auth
HUB_AUTH_VALUES ?= deploy/platform-mvp/kind/hub-auth-values.yaml
.PHONY: ensure-hub-auth-config
ensure-hub-auth-config:
	@mkdir -p "$(HUB_AUTH_DIR)" 2>/dev/null || { \
		echo "ERROR: cannot create $(HUB_AUTH_DIR) (likely root-owned after a host reboot)."; \
		exit 1; \
	}
	@CA=$$(kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) get secret ingress-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null); \
	F="$(HUB_AUTH_DIR)/authentication-configuration.yaml"; \
	if [ -n "$$CA" ]; then \
		printf '%s\n' "$$CA" > "$(HUB_AUTH_DIR)/dex-ca.crt" && \
		./hack/platform-mvp/render-spoke-auth-config.sh $(SPOKE_CHART) $(HUB_AUTH_VALUES) "" "$(HUB_AUTH_DIR)/dex-ca.crt" "$(DEX_ISSUER)" > "$$F.new" && \
		mv "$$F.new" "$$F" && echo "  hub AuthenticationConfiguration ready at $$F" || exit 1; \
	elif [ ! -s "$$F" ]; then \
		printf 'apiVersion: apiserver.config.k8s.io/v1beta1\nkind: AuthenticationConfiguration\njwt: []\n' > "$$F" && \
		echo "  hub AuthenticationConfiguration placeholder written (Dex CA not available yet)"; \
	fi

# hub must exist before ensure-spoke-auth-config (needs its CA cert), and
# that must finish before any spoke starts (it reads the host-mounted file at
# kube-apiserver boot) — no longer parallel.
clusters:
	@echo "==> Creating hub cluster"
	@if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_HUB)"; then \
		$(MAKE) --no-print-directory render-kind-config-$(KIND_HUB) ensure-hub-auth-config && \
		kind create cluster --name $(KIND_HUB) --config $(KIND_HUB_CONFIG); \
	fi
	$(MAKE) ensure-spoke-auth-config
	@for s in $(SPOKES); do \
		echo "==> Creating $$s cluster"; \
		if ! kind get clusters 2>/dev/null | grep -qx "$$s"; then \
			kind create cluster --name $$s --config $(KIND_RENDER_DIR)/kind-$$s.yaml || exit 1; \
		fi; \
	done
	@echo "  Verifying nodes..."
	kubectl --context kind-$(KIND_HUB) get nodes
	@for s in $(SPOKES); do kubectl --context kind-$$s get nodes || exit 1; done
	@echo "  Extracting internal kubeconfigs + generating E2E kubeconfigs..."
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	@for s in $(SPOKES); do \
		kind get kubeconfig --name $$s --internal > $(SPOKE_KC_DIR)/kubeconfig-$$s-internal; \
		kind get kubeconfig --name $$s --internal > $(CHAINSAW_DIR)/kubeconfig-$$s-internal; \
		IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $$s-control-plane 2>/dev/null); \
		if [ -n "$$IP" ]; then \
			sed -i "s|https://$$s-control-plane:6443|https://$$IP:6443|" $(CHAINSAW_DIR)/kubeconfig-$$s-internal; \
		fi; \
	done
	@echo "==> Clusters ready"

# ── Deploy ───────────────────────────────────────────────────────────────────
# Wave-based deployment: each wave is a Helm chart that groups related resources.
# Flux/GitOps path mirrors this with HelmRelease dependsOn chains.
.PHONY: deploy deploy-wave1 deploy-wave2 deploy-wave3 deploy-wave4

deploy: crds
	@echo "==> Building images and creating clusters in parallel"
	$(MAKE) build-images-parallel & \
	$(MAKE) clusters & \
	wait
	$(MAKE) load-images
	@echo "==> Wave 1: CRDs on hub + spokes"
	$(MAKE) deploy-wave1
	@echo "==> Wave 2 (infra on hub) + Wave 4 (spokes) in parallel"
	@$(MAKE) --no-print-directory deploy-wave2 & \
	$(MAKE) --no-print-directory deploy-wave4 & \
	wait
	@echo "==> Wave 2: Infrastructure on hub"
	$(MAKE) deploy-wave2
	@echo "  Waiting for ingress-tls cert (Dex CA source) to be issued..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) wait --for=jsonpath='{.data.ca\.crt}' secret/ingress-tls --timeout=60s
	@echo "  Refreshing AuthenticationConfigurations of spokes and hub (Dex CA now available)..."
	$(MAKE) ensure-spoke-auth-config ensure-hub-auth-config
	$(MAKE) tenant-kubeconfigs
	$(MAKE) ensure-portal-clusters
	@echo "==> Wave 3: Hub services on hub"
	$(MAKE) deploy-wave3
	@echo "==> Management plane on hub (portal + measurement; needs Dex's client from wave 2 and the hub's refreshed trust)"
	$(MAKE) deploy-management-plane
	@echo "==> In-cluster Chainsaw runner (CronJob needs its image and kubeconfig Secret)"
	$(MAKE) chainsaw-runner
	@echo "==> Platform deploy complete (Flux not yet installed — run 'make deploy-cd' for GitOps)"

# ── Wave 1: CRDs (hub and every spoke, cluster-scoped) ───────────────────────
deploy-wave1: crds
	@echo "==> Wave 1: Installing platform CRDs on hub + spokes"
	helm upgrade --install $(CRDS_RELEASE) $(CRDS_CHART) \
		-n $(CRDS_NS) --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_HUB)
	@for s in $(SPOKES); do \
		helm upgrade --install $(CRDS_RELEASE) $(CRDS_CHART) -n $(CRDS_NS) \
			--create-namespace --wait --timeout $(HELM_TIMEOUT) \
			--kube-context kind-$$s || exit 1; \
	done
	@echo "  Waiting for Kro CRDs..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/regionalbucketrequests.platform.example.com crd/regionalvmsetrequests.platform.example.com --timeout=30s
	@echo "==> Wave 1 complete"

# ── Wave 2: Infrastructure (hub context) ──────────────────────────────────────
# Dex trusts the service-account issuer of each WORKLOAD_SPOKE. kind's CA is not publicly
# trusted, so it is read from the spoke fresh each run and stored as <spoke>.crt (the chart's
# dex.workloadConnectors[].caKey).
WORKLOAD_SPOKES        ?= us
DEX_UPSTREAM_CA_SECRET ?= dex-upstream-ca
.PHONY: ensure-dex-upstream-ca
ensure-dex-upstream-ca:
	@kubectl --context kind-$(KIND_HUB) create namespace $(OBS_NS) --dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - > /dev/null
	@d=$$(mktemp -d); args=""; \
	for s in $(WORKLOAD_SPOKES); do \
		docker exec $$s-control-plane cat /etc/kubernetes/pki/ca.crt > $$d/$$s.crt || exit 1; \
		args="$$args --from-file=$$s.crt=$$d/$$s.crt"; \
	done; \
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) create secret generic $(DEX_UPSTREAM_CA_SECRET) $$args --dry-run=client -o yaml \
		| kubectl --context kind-$(KIND_HUB) apply -f -; \
	rm -rf $$d

deploy-wave2: ensure-dex-upstream-ca
	@echo "==> Wave 2: Installing infrastructure on hub"
	@if [ "$(INFRA_CHART)/Chart.lock" -ot "$(INFRA_CHART)/Chart.yaml" ]; then \
		echo "  Chart.yaml changed, running helm dependency update..."; \
		helm dependency update $(INFRA_CHART) > /dev/null; \
	else \
		echo "  Chart.lock is fresh, skipping helm dependency update"; \
	fi
	helm upgrade --install $(INFRA_RELEASE) $(INFRA_CHART) \
		-n $(OBS_NS) --create-namespace --timeout $(HELM_TIMEOUT) \
		--set ingress.host=$(INGRESS_HOST) --set dex.upstreamCaSecret=$(DEX_UPSTREAM_CA_SECRET) \
		-f $(INFRA_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "  Waiting for core infra..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager --timeout=2m &
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager-webhook --timeout=2m &
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-ingress-nginx-controller --timeout=2m &
	wait
	@echo "  Waiting for Dex..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/dex --timeout=2m
	@echo "  Enabling Grafana Ingress..."
	helm upgrade $(INFRA_RELEASE) $(INFRA_CHART) -n $(OBS_NS) --timeout 60s \
		--set ingress.host=$(INGRESS_HOST) --set dex.upstreamCaSecret=$(DEX_UPSTREAM_CA_SECRET) --set ingress.enabled=true \
		-f $(INFRA_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "  Waiting for Grafana (may have restarted from the ingress upgrade)..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-grafana --timeout=60s
	@echo "  Waiting for Grafana's dashboard-sidecar to provision ConfigMap dashboards..."
	@echo "  (sidecar sync lag after a fresh deploy is observed to vary widely — up to ~90s)"
	kubectl --context kind-$(KIND_HUB) run dashboard-wait --rm -i --restart=Never --image=curlimages/curl -n $(OBS_NS) -- \
		sh -c 'for i in $$(seq 1 40); do CODE=$$(curl -s -o /dev/null -w "%{http_code}" http://admin:admin@hub-grafana/api/dashboards/uid/controller-deep-dive); [ "$$CODE" = "200" ] && exit 0; sleep 3; done; exit 1'
	@echo "==> Wave 2 complete"

# ── Wave 3: Hub services (hub context) ────────────────────────────────────────
deploy-wave3:
	@echo "==> Wave 3: Installing hub services on hub"
	@for s in $(SPOKES); do \
		[ -f $(SPOKE_KC_DIR)/kubeconfig-$$s-internal ] || kind get kubeconfig --name $$s --internal > $(SPOKE_KC_DIR)/kubeconfig-$$s-internal; \
	done
	kubectl --context kind-$(KIND_HUB) create namespace kro-system 2>/dev/null || true
	helm upgrade --install $(HUBSVC_RELEASE) $(HUBSVC_CHART) \
		-n $(HUBSVC_NS) --create-namespace --timeout $(HELM_TIMEOUT) \
		-f $(HUBSVC_CHART)/e2e-values.yaml -f $(TENANTS_FILE) \
		--set vmBindingController.image.repository=$(DOCKER_REGISTRY)/vm-binding-controller --set vmBindingController.image.tag=$(IMAGE_TAG) \
		--set bucketBindingController.image.repository=$(DOCKER_REGISTRY)/bucket-binding-controller --set bucketBindingController.image.tag=$(IMAGE_TAG) \
		--kube-context kind-$(KIND_HUB)
	@echo "  Creating secrets..."
	@for s in $(SPOKES); do \
		kubectl --context kind-$(KIND_HUB) create secret generic $$s-kubeconfig \
			--from-file=value=$(SPOKE_KC_DIR)/kubeconfig-$$s-internal \
			--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - || exit 1; \
	done
	@echo "  Waiting for controllers..."
	kubectl --context kind-$(KIND_HUB) -n $(HUBSVC_NS) rollout status deployment/vm-binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n $(HUBSVC_NS) rollout status deployment/bucket-binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deployment/kro --timeout=2m
	@echo "==> Wave 3 complete"

# ── Management plane (hub context, after wave 3) ──────────────────────────────
# Measures the intents Kro serves, so it needs wave 3, and logs people in through Dex (wave 2, which
# must already know the portal's client: run deploy-wave2 and ensure-hub-auth-config first on a hub
# deployed before this existed). The operator's CRDs came with wave 1.
.PHONY: deploy-management-plane
deploy-management-plane:
	@echo "==> Management plane on hub"
	@if [ "$(MGMT_CHART)/Chart.lock" -ot "$(MGMT_CHART)/Chart.yaml" ]; then \
		echo "  Chart.yaml changed, running helm dependency update..."; \
		helm dependency update $(MGMT_CHART) > /dev/null; \
	else \
		echo "  Chart.lock is fresh, skipping helm dependency update"; \
	fi
	helm upgrade --install $(MGMT_RELEASE) $(MGMT_CHART) \
		-n $(OBS_NS) --timeout $(HELM_TIMEOUT) --set ingress.host=$(INGRESS_HOST) --kube-context kind-$(KIND_HUB)
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/metrics-operator --timeout=2m
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/headlamp --timeout=3m
	@echo "==> Management plane complete"

# ── Wave 4: Spokes (one chart, per-spoke values) ─────────────────────────────
# The one command that installs the spoke chart on spoke $$s (shell variable of the calling loop).
SPOKE_HELM = helm upgrade --install $$s $(SPOKE_CHART) -f $(SPOKE_CHART)/values-$$s.yaml -f $(TENANTS_FILE) \
	--set oidcVerifier.image.repository=$(DOCKER_REGISTRY)/oidc-verifier --set oidcVerifier.image.tag=$(IMAGE_TAG) \
	--set authConfiguration.dexIssuer.url=$(DEX_ISSUER) \
	-n default --create-namespace --wait --timeout $(HELM_TIMEOUT) --kube-context kind-$$s

deploy-wave4:
	@for s in $(SPOKES); do \
		echo "==> Wave 4: Installing spoke $$s"; \
		kubectl --context kind-$$s create namespace default --dry-run=client -o yaml | kubectl --context kind-$$s apply -f - || exit 1; \
		if echo " $(KUBEVIRT_SPOKES) " | grep -q " $$s "; then \
			echo "  Installing KubeVirt operator $(KUBEVIRT_VERSION) on $$s"; \
			kubectl --context kind-$$s apply -f $(CRDS_DIR)/kubevirt-operator.yaml > /dev/null || exit 1; \
			kubectl --context kind-$$s wait --for=condition=Established crd/kubevirts.kubevirt.io --timeout=60s || exit 1; \
		fi; \
		$(SPOKE_HELM) || exit 1; \
		kubectl --context kind-$$s -n default rollout status deployment/oidc-verifier --timeout=60s || exit 1; \
		if echo " $(KUBEVIRT_SPOKES) " | grep -q " $$s "; then \
			echo "  Waiting for KubeVirt on $$s (operator rolls out its components)"; \
			kubectl --context kind-$$s -n kubevirt wait kv/kubevirt --for=condition=Available --timeout=10m || exit 1; \
		fi; \
		if echo " $(ROOK_SPOKES) " | grep -q " $$s "; then \
			$(MAKE) --no-print-directory deploy-rook-$$s || exit 1; \
		fi; \
	done
	@echo "==> Wave 4 complete"

# ── Rook/Ceph on storage spokes ──────────────────────────────────────────────
.PHONY: deploy-rook
deploy-rook: $(addprefix deploy-rook-,$(ROOK_SPOKES))

# Create the OSD loop device in the worker (idempotent: reuse an existing one),
# install the operator then the cluster with that device, wait for the S3 store.
# A host reboot drops the loop device and reattaching may pick another number; Rook
# keeps an existing OSD's device path from its Deployment, so point the OSDs at the
# current device and wait for them before trusting the store's (lagging) status.
deploy-rook-%:
	@echo "==> Rook/Ceph on $*"
	@DEV=$$(docker exec $*-worker losetup -j $(CEPH_LOOP_IMG) | cut -d: -f1 | head -n1); \
	if [ -z "$$DEV" ]; then \
		DEV=$$(docker exec $*-worker sh -c 'truncate -s $(CEPH_LOOP_SIZE) $(CEPH_LOOP_IMG) && losetup -f --show $(CEPH_LOOP_IMG)') || exit 1; \
	fi; \
	echo "  OSD device: $$DEV"; \
	helm upgrade --install rook-ceph rook-ceph --repo $(ROOK_REPO) --version $(ROOK_VERSION) \
		-n $(ROOK_NS) --create-namespace -f $(ROOK_DIR)/operator-values.yaml \
		--wait --timeout $(HELM_TIMEOUT) --kube-context kind-$* || exit 1; \
	helm upgrade --install rook-ceph-cluster rook-ceph-cluster --repo $(ROOK_REPO) --version $(ROOK_VERSION) \
		-n $(ROOK_NS) -f $(ROOK_DIR)/cluster-values.yaml \
		--set "cephClusterSpec.storage.devices[0].name=$$DEV" \
		--timeout $(HELM_TIMEOUT) --kube-context kind-$* || exit 1; \
	for d in $$(kubectl --context kind-$* -n $(ROOK_NS) get deploy -l app=rook-ceph-osd -o name); do \
		kubectl --context kind-$* -n $(ROOK_NS) set env $$d --containers='*' ROOK_BLOCK_PATH=$$DEV || exit 1; \
		kubectl --context kind-$* -n $(ROOK_NS) rollout status $$d --timeout=$(ROOK_TIMEOUT) || exit 1; \
	done
	kubectl --context kind-$* -n $(ROOK_NS) wait cephobjectstore/s3 --for=jsonpath='{.status.phase}'=Ready --timeout=$(ROOK_TIMEOUT)
	sed 's|__S3_NODE_PORT__|$(S3_NODE_PORT)|' $(ROOK_DIR)/s3-public-service.yaml.tmpl | kubectl --context kind-$* apply -f -

# ── Flux / GitOps ────────────────────────────────────────────────────────────
.PHONY: deploy-flux deploy-cd verify-all

deploy-flux:
	@echo "==> Installing Flux controllers on hub"
	flux install --components=source-controller,helm-controller,kustomize-controller \
		--context=kind-$(KIND_HUB) --namespace=flux-system
	@echo "==> Applying Flux bootstrap (the Kustomization then applies the releases, with its substitutions)"
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/bootstrap/flux-setup.yaml
	kubectl --context kind-$(KIND_HUB) -n flux-system wait kustomization/$(FLUX_KS_NAME) --for=condition=Ready --timeout=5m
	@echo "==> Flux ready"

# Same install as deploy-flux; from here Flux takes over the hub HelmReleases.
deploy-cd: deploy-flux
	@echo "==> GitOps enabled — Flux now manages the hub HelmRelease"

# Run after deploy-cd on a lab that make deploy built: Flux is healthy and took the releases over without
# changing the lab (no second copy of a release, the CRDs keep their owner, Dex keeps its issuer).
.PHONY: verify-flux
verify-flux:
	@echo "==> checking that Flux took over the hub releases without changing the lab"
	@K="kubectl --context kind-$(KIND_HUB)"; fail=0; \
	chk() { m="$$1"; shift; if "$$@" >/dev/null 2>&1; then echo "  PASS: $$m"; else echo "  FAIL: $$m"; fail=1; fi; }; \
	chk "the Git source is Ready" $$K -n flux-system wait gitrepository/platform --for=condition=Ready --timeout=2m; \
	chk "the Kustomization is Ready" $$K -n flux-system wait kustomization/$(FLUX_KS_NAME) --for=condition=Ready --timeout=2m; \
	chk "HelmRelease crds is Ready" $$K -n flux-system wait helmrelease/crds --for=condition=Ready --timeout=10m; \
	chk "HelmRelease infrastructure is Ready" $$K -n $(OBS_NS) wait helmrelease/infrastructure --for=condition=Ready --timeout=15m; \
	chk "HelmRelease hub-services is Ready" $$K -n $(HUBSVC_NS) wait helmrelease/hub-services --for=condition=Ready --timeout=10m; \
	chk "HelmRelease management-plane is Ready" $$K -n $(OBS_NS) wait helmrelease/management-plane --for=condition=Ready --timeout=10m; \
	have=$$(helm --kube-context kind-$(KIND_HUB) ls -A -o json 2>/dev/null | python3 -I -c 'import json, sys; print(" ".join(sorted("%s/%s" % (r["name"], r["namespace"]) for r in json.load(sys.stdin))))'); \
	want=$$(printf '%s\n' $(CRDS_RELEASE)/$(CRDS_NS) $(INFRA_RELEASE)/$(OBS_NS) $(HUBSVC_RELEASE)/$(HUBSVC_NS) $(MGMT_RELEASE)/$(OBS_NS) | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $$//'); \
	chk "the Helm releases are exactly: $$want" [ "$$have" = "$$want" ]; \
	owner=$$($$K get crd resourcegraphdefinitions.kro.run -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null); \
	chk "the CRDs still belong to the release in $(CRDS_NS)" [ "$$owner" = "$(CRDS_NS)" ]; \
	issuer=$$($$K -n $(OBS_NS) get cm dex-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -m1 '^issuer:'); \
	chk "Dex's issuer is $(DEX_ISSUER)" [ "$$issuer" = "issuer: $(DEX_ISSUER)" ]; \
	chk "Dex rolled out" $$K -n $(OBS_NS) rollout status deploy/dex --timeout=2m; \
	bad=$$($$K get pods -A --no-headers 2>/dev/null | grep -cE 'CrashLoopBackOff|ImagePullBackOff|Pending'); \
	chk "no pod is crash-looping, pending or missing its image" [ "$$bad" = 0 ]; \
	[ $$fail = 0 ]

verify-all:
	@echo "==> Full clean-room validation: clean → deploy → validate → deploy-cd"
	$(MAKE) clean
	$(MAKE) deploy
	$(MAKE) validate
	$(MAKE) deploy-cd
	@echo "==> Full validation complete (GitOps enabled)"

# ── Chainsaw runner ──────────────────────────────────────────────────────────
.PHONY: chainsaw-runner
chainsaw-runner:
	docker build --build-arg CHAINSAW_VERSION=$(CHAINSAW_VERSION) -t chainsaw-runner:local -f $(CHAINSAW_RUNNER_DIR)/Dockerfile.chainsaw-runner .
	kind load docker-image chainsaw-runner:local --name $(KIND_HUB)
	@echo "  Setting up kubeconfig secrets for CronJob (cluster-internal addresses)..."
	kind get kubeconfig --name $(KIND_HUB) --internal > $(SPOKE_KC_DIR)/kubeconfig-$(KIND_HUB)-internal
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) create secret generic kubeconfigs \
		--from-file=hub="$(SPOKE_KC_DIR)/kubeconfig-$(KIND_HUB)-internal" \
		$(foreach s,$(SPOKES),--from-file=$(s)="$(SPOKE_KC_DIR)/kubeconfig-$(s)-internal") \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) apply -f -

# Chainsaw has no impersonation, so each tenant gets a copy of the hub kubeconfig that acts as the
# tenant's workload identity (kubeconfig-hub-<tenant>, chainsaw cluster hub-<tenant>): intents are
# created by their tenant, not by the cluster admin, which admission refuses.
.PHONY: chainsaw-kubeconfigs
chainsaw-kubeconfigs:
	@python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); w = d["workloadIdentity"]; \
	[print(t["id"], "%s%s:system:serviceaccount:%s:%s" % (w["userPrefix"], w["connectorId"], t["id"], w["serviceAccount"])) for t in d["tenants"]]' $(TENANTS_FILE) | \
	while read tenant user; do \
		cp $(CHAINSAW_DIR)/kubeconfig-hub $(CHAINSAW_DIR)/kubeconfig-hub-$$tenant; \
		sed -i "s|^  user:\$$|&\n    as: $$user|" $(CHAINSAW_DIR)/kubeconfig-hub-$$tenant; \
	done

.PHONY: tenant-kubeconfigs
tenant-kubeconfigs:
	@echo "==> Writing a kubeconfig per tenant to $(TENANT_KUBECONFIG_DIR) (Dex login with kubelogin)"
	@DEXCA=$$(kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) get secret ingress-tls -o jsonpath='{.data.ca\.crt}'); \
	[ -n "$$DEXCA" ] || { echo "ERROR: no Dex CA yet (secret $(OBS_NS)/ingress-tls)"; exit 1; }; \
	for t in $$(python3 -I -c 'import sys, yaml; [print(t["id"]) for t in yaml.safe_load(open(sys.argv[1]))["tenants"]]' $(TENANTS_FILE)); do \
		out=$(TENANT_KUBECONFIG_DIR)/kubeconfig-$$t; rm -f $$out; \
		for c in $(KIND_HUB) $(SPOKES); do \
			src=$$(mktemp); kind get kubeconfig --name $$c > $$src || exit 1; \
			kubectl --kubeconfig $$out config set-cluster $$c --server=$$(kubectl --kubeconfig $$src config view --raw -o jsonpath='{.clusters[0].cluster.server}') >/dev/null; \
			kubectl --kubeconfig $$out config set clusters.$$c.certificate-authority-data $$(kubectl --kubeconfig $$src config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}') >/dev/null; \
			kubectl --kubeconfig $$out config set-context $$c --cluster=$$c --user=dex --namespace=$$t >/dev/null; \
			rm -f $$src; \
		done; \
		kubectl --kubeconfig $$out config set-credentials dex --exec-api-version=client.authentication.k8s.io/v1 \
			--exec-command=kubelogin --exec-interactive-mode=IfAvailable --exec-arg=get-token \
			--exec-arg=--oidc-issuer-url=$(DEX_ISSUER) --exec-arg=--oidc-client-id=$(DEX_CLIENT_ID) \
			$(foreach s,$(OIDC_LOGIN_SCOPES),--exec-arg=--oidc-extra-scope=$(s)) \
			--exec-arg=--certificate-authority-data=$$DEXCA --exec-arg=--grant-type=$(OIDC_LOGIN_GRANT) --exec-arg=--oidc-redirect-url=$(OIDC_LOGIN_REDIRECT) \
			--exec-arg=--token-cache-dir=$$HOME/.kube/cache/oidc-login/$$t >/dev/null; \
		kubectl --kubeconfig $$out config use-context $(KIND_HUB) >/dev/null; \
		echo "  $$out"; \
	done

# The portal shows the spokes too: a kubeconfig for Headlamp (Secret PORTAL_CLUSTERS_SECRET) with
# each spoke's address and CA as the hub's pods reach it, and a Dex login (OIDC) for each spoke.
PORTAL_CLUSTERS_SECRET ?= headlamp-clusters
PORTAL_OIDC_SCOPES     ?= profile,email,groups
.PHONY: ensure-portal-clusters
ensure-portal-clusters:
	@echo "==> Writing the portal's spoke kubeconfig (Secret $(OBS_NS)/$(PORTAL_CLUSTERS_SECRET))"
	@DEXCA=$$(kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) get secret ingress-tls -o jsonpath='{.data.ca\.crt}'); \
	[ -n "$$DEXCA" ] || { echo "ERROR: no Dex CA yet (secret $(OBS_NS)/ingress-tls)"; exit 1; }; \
	d=$$(mktemp -d); kc=$$d/kubeconfig; \
	for s in $(SPOKES); do docker exec $$s-control-plane cat /etc/kubernetes/pki/ca.crt > $$d/$$s.crt || exit 1; done; \
	python3 -I -c 'import base64, sys, yaml; \
	d, port, issuer, client, dexca, scopes = sys.argv[1:7]; spokes = sys.argv[7:]; \
	ca = lambda s: base64.b64encode(open("%s/%s.crt" % (d, s), "rb").read()).decode(); \
	oidc = {"idp-issuer-url": issuer, "client-id": client, "idp-certificate-authority-data": dexca, "scope": scopes}; \
	print(yaml.safe_dump({"apiVersion": "v1", "kind": "Config", \
	"clusters": [{"name": s, "cluster": {"server": "https://%s-control-plane:%s" % (s, port), "certificate-authority-data": ca(s)}} for s in spokes], \
	"users": [{"name": s, "user": {"auth-provider": {"name": "oidc", "config": oidc}}} for s in spokes], \
	"contexts": [{"name": s, "context": {"cluster": s, "user": s}} for s in spokes]}))' \
	$$d $(SPOKE_API_PORT) $(DEX_ISSUER) $(DEX_CLIENT_ID) $$DEXCA $(PORTAL_OIDC_SCOPES) $(SPOKES) > $$kc || exit 1; \
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) create secret generic $(PORTAL_CLUSTERS_SECRET) --from-file=kubeconfig=$$kc \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f -; \
	rm -rf $$d

# ── Validate ─────────────────────────────────────────────────────────────────
.PHONY: validate
validate: ensure-spoke-auth-config ensure-hub-auth-config tenant-kubeconfigs
	@echo "==> Running full Chainsaw E2E test suite"
	@mkdir -p $(CHAINSAW_DIR)
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	@for s in $(SPOKES); do kind get kubeconfig --name $$s > $(CHAINSAW_DIR)/kubeconfig-$$s-internal || exit 1; done
	$(MAKE) --no-print-directory chainsaw-kubeconfigs
	cd $(CHAINSAW_DIR) && chainsaw test . --test-dir tests --fail-fast=false \
		--report-format JSON --report-name $(CHAINSAW_REPORT)

# ── Grafana ──────────────────────────────────────────────────────────────────
.PHONY: grafana grafana-url
grafana:
	@echo "Port-forwarding Grafana → http://localhost:$(GRAFANA_PF_PORT)"
	@echo "  Login: admin / admin"
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) port-forward svc/hub-grafana $(GRAFANA_PF_PORT):80

grafana-url:
	@echo "Grafana: $(GRAFANA_URL)  ·  Login: admin / admin"
	@echo ""
	@echo "  $(GRAFANA_URL)/d/cluster-fitness       Cluster Fitness"
	@echo "  $(GRAFANA_URL)/d/chainsaw-results       Chainsaw Test Results"
	@echo "  $(GRAFANA_URL)/d/controller-deep-dive   Controller Deep Dive"
	@echo "  $(GRAFANA_URL)/d/platform-adoption      Platform adoption"
	@echo ""
	@echo "Portal: https://$(INGRESS_HOST)/headlamp/  ·  Login at Dex: alice@acme-corp.example.com / password"

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean clean-artifacts
clean:
	kind delete cluster --name $(KIND_HUB) 2>/dev/null || true
	@for s in $(ROOK_SPOKES); do docker exec $$s-worker losetup -d $$(docker exec $$s-worker losetup -j $(CEPH_LOOP_IMG) | cut -d: -f1) 2>/dev/null || true; done
	@for s in $(SPOKES); do kind delete cluster --name $$s 2>/dev/null || true; done
	@for s in $(SPOKES); do rm -f $(SPOKE_KC_DIR)/kubeconfig-$$s-internal $(CHAINSAW_DIR)/kubeconfig-$$s-internal; done
	rm -f $(CHAINSAW_DIR)/kubeconfig-hub $(CHAINSAW_DIR)/kubeconfig-hub-* $(CHAINSAW_DIR)/$(CHAINSAW_REPORT)

clean-artifacts:
	rm -rf $(OUT_DIR) coverage-root.out coverage-vmbc.out coverage-bbc.out

# ── Full loop ────────────────────────────────────────────────────────────────
.PHONY: all
all: lint test build deploy validate
	@echo "==> Full loop complete"

# ── Install helpers ──────────────────────────────────────────────────────────
.PHONY: install-chainsaw install-flux install-kubelogin install-virtctl
install-chainsaw:
	go install github.com/kyverno/chainsaw@$(CHAINSAW_VERSION)

install-kubelogin:
	go install github.com/int128/kubelogin@$(KUBELOGIN_VERSION)

# virtctl of the KubeVirt release that runs on the VM spokes (ssh and console into tenant VMs).
VIRTCTL_BIN ?= $(shell go env GOPATH)/bin/virtctl
install-virtctl:
	curl -fsSL -o $(VIRTCTL_BIN) https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/virtctl-$(KUBEVIRT_VERSION)-$(shell go env GOOS)-$(shell go env GOARCH)
	chmod +x $(VIRTCTL_BIN)

install-flux:
	curl -s https://fluxcd.io/install.sh | bash