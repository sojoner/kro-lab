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
KIND_HUB_CONFIG   ?= deploy/platform-mvp/kind/kind-hub.yaml

# Spoke clusters (kind cluster name == spoke name == ClusterProfile name ==
# chart/spoke/values-<name>.yaml). Adding a spoke = one entry here plus a
# KIND_NODE_IMAGE_<name>, a values file, and a hub-services fleet entry.
SPOKES            ?= us eu eu-storage
KIND_NODE_IMAGE_us ?= kindest/node:v1.30.0
# KubeVirt 1.9 supports Kubernetes 1.34-1.36 only.
KIND_NODE_IMAGE_eu ?= kindest/node:v1.35.1
KIND_NODE_IMAGE_eu-storage ?= kindest/node:v1.35.1
KIND_SPOKE_CONFIG_TMPL ?= deploy/platform-mvp/kind/kind-spoke.yaml.tmpl
# Spokes hosting a Ceph OSD get a template that also mounts the host udev db.
KIND_SPOKE_CONFIG_TMPL_eu-storage ?= deploy/platform-mvp/kind/kind-spoke-storage.yaml.tmpl
HOST_UDEV_DIR     ?= /run/udev
KIND_RENDER_DIR   ?= deploy/platform-mvp/kind/rendered
# Per-spoke apiserver auth dir, mounted into the spoke's control plane.
# Readable/writable by the invoking user (no root-owned /tmp race, survives
# host reboots) — always resolved relative to KIND_SPOKE_CONFIG_TMPL's own
# location, never a machine-specific absolute path. Spoke X uses X-auth/.
SPOKE_AUTH_BASE   ?= $(abspath $(dir $(KIND_SPOKE_CONFIG_TMPL)))

INFRA_CHART        ?= deploy/platform-mvp/chart/infrastructure
SPOKE_CHART        ?= deploy/platform-mvp/chart/spoke
CRDS_CHART         ?= deploy/platform-mvp/chart/crds
HUBSVC_CHART       ?= deploy/platform-mvp/chart/hub-services
HELM_TIMEOUT       ?= 15m

INGRESS_HOST       ?= bm4080.taildf7067.ts.net
GRAFANA_URL        ?= http://$(INGRESS_HOST)
GRAFANA_PF_PORT    ?= 3000
OBS_NS             ?= monitoring

SPOKE_KC_DIR       ?= hack/platform-mvp

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

# KubeVirt runs only on these spokes (needs /dev/kvm on the host). Its operator
# manifest is cached under CRDS_DIR like the other upstream manifests.
KUBEVIRT_VERSION   ?= v1.9.1
KUBEVIRT_SPOKES    ?= eu

# Rook/Ceph (S3 via RADOS Gateway) runs on these spokes. Each gets a loop-device
# OSD created inside its worker node (privileged kind node, no host sudo).
ROOK_VERSION       ?= 1.21.1
ROOK_REPO          ?= https://charts.rook.io/release
ROOK_NS            ?= rook-ceph
ROOK_DIR           ?= deploy/platform-mvp/rook
ROOK_SPOKES        ?= eu-storage
CEPH_LOOP_SIZE     ?= 20G
CEPH_LOOP_IMG      ?= /var/lib/ceph-osd.img
ROOK_TIMEOUT       ?= 10m

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Platform MVP — build, deploy, validate"
	@echo ""
	@echo "Deploy (4-wave Helm chart decomposition):"
	@echo "  make deploy        Full deployment (clusters + 4 waves)"
	@echo "  make deploy-wave1  Wave 1: Install all CRDs on hub + spokes"
	@echo "  make deploy-wave2  Wave 2: Infrastructure on hub (LGTM + Dex + ingress)"
	@echo "  make deploy-wave3  Wave 3: Hub services (Kro + VM/bucket binding controllers + fleet)"
	@echo "  make deploy-wave4  Wave 4: Spokes (oidc-verifier + tenant RBAC; KubeVirt on KUBEVIRT_SPOKES, Rook/Ceph on ROOK_SPOKES)"
	@echo "  make deploy-rook   Rook/Ceph + RADOS Gateway on ROOK_SPOKES (also part of wave 4)"
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
.PHONY: lint lint-fix check-retired check-runner-tests
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

lint: check-retired check-runner-tests
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
      $(CRDS_DIR)/kubevirt-operator.yaml

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
	./hack/platform-mvp/render-spoke-auth-config.sh $(SPOKE_CHART) $(SPOKE_CHART)/values-$*.yaml "$(SPOKE_AUTH_BASE)/$*-auth/hub-ca.crt" "$$DEX_CA" > "$(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml" 2>/dev/null || { \
		echo "ERROR: cannot write $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml (likely root-owned after a host reboot)."; \
		echo "  Run this once, then retry:"; \
		echo "  ./hack/platform-mvp/render-spoke-auth-config.sh $(SPOKE_CHART) $(SPOKE_CHART)/values-$*.yaml $(SPOKE_AUTH_BASE)/$*-auth/hub-ca.crt | sudo tee $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml > /dev/null"; \
		exit 1; \
	}
	@echo "  $* AuthenticationConfiguration ready at $(SPOKE_AUTH_BASE)/$*-auth/authentication-configuration.yaml"

# hub must exist before ensure-spoke-auth-config (needs its CA cert), and
# that must finish before any spoke starts (it reads the host-mounted file at
# kube-apiserver boot) — no longer parallel.
clusters:
	@echo "==> Creating hub cluster"
	@if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_HUB)"; then \
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
	@echo "  Refreshing spoke AuthenticationConfigurations (Dex CA now available)..."
	$(MAKE) ensure-spoke-auth-config
	@echo "==> Wave 3: Hub services on hub"
	$(MAKE) deploy-wave3
	@echo "==> In-cluster Chainsaw runner (CronJob needs its image and kubeconfig Secret)"
	$(MAKE) chainsaw-runner
	@echo "==> Platform deploy complete (Flux not yet installed — run 'make deploy-cd' for GitOps)"

# ── Wave 1: CRDs (hub and every spoke, cluster-scoped) ───────────────────────
deploy-wave1: crds
	@echo "==> Wave 1: Installing platform CRDs on hub + spokes"
	helm upgrade --install crds $(CRDS_CHART) \
		--create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_HUB)
	@for s in $(SPOKES); do \
		helm upgrade --install crds $(CRDS_CHART) \
			--create-namespace --wait --timeout $(HELM_TIMEOUT) \
			--kube-context kind-$$s || exit 1; \
	done
	@echo "  Waiting for Kro CRDs..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/regionalbucketrequests.platform.example.com crd/regionalvmsetrequests.platform.example.com --timeout=30s
	@echo "==> Wave 1 complete"

# ── Wave 2: Infrastructure (hub context) ──────────────────────────────────────
deploy-wave2:
	@echo "==> Wave 2: Installing infrastructure on hub"
	@if [ "$(INFRA_CHART)/Chart.lock" -ot "$(INFRA_CHART)/Chart.yaml" ]; then \
		echo "  Chart.yaml changed, running helm dependency update..."; \
		helm dependency update $(INFRA_CHART) > /dev/null; \
	else \
		echo "  Chart.lock is fresh, skipping helm dependency update"; \
	fi
	helm upgrade --install hub $(INFRA_CHART) \
		-n $(OBS_NS) --create-namespace --timeout $(HELM_TIMEOUT) \
		--set ingress.host=$(INGRESS_HOST) \
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
	helm upgrade hub $(INFRA_CHART) -n $(OBS_NS) --timeout 60s \
		--set ingress.host=$(INGRESS_HOST) --set ingress.enabled=true \
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
	helm upgrade --install hub-services $(HUBSVC_CHART) \
		-n default --create-namespace --timeout $(HELM_TIMEOUT) \
		-f $(HUBSVC_CHART)/e2e-values.yaml \
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
	kubectl --context kind-$(KIND_HUB) -n default rollout status deployment/vm-binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n default rollout status deployment/bucket-binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deployment/kro --timeout=2m
	@echo "==> Wave 3 complete"

# ── Wave 4: Spokes (one chart, per-spoke values) ─────────────────────────────
deploy-wave4:
	@for s in $(SPOKES); do \
		echo "==> Wave 4: Installing spoke $$s"; \
		kubectl --context kind-$$s create namespace default --dry-run=client -o yaml | kubectl --context kind-$$s apply -f - || exit 1; \
		if echo " $(KUBEVIRT_SPOKES) " | grep -q " $$s "; then \
			echo "  Installing KubeVirt operator $(KUBEVIRT_VERSION) on $$s"; \
			kubectl --context kind-$$s apply -f $(CRDS_DIR)/kubevirt-operator.yaml > /dev/null || exit 1; \
			kubectl --context kind-$$s wait --for=condition=Established crd/kubevirts.kubevirt.io --timeout=60s || exit 1; \
		fi; \
		helm upgrade --install $$s $(SPOKE_CHART) -f $(SPOKE_CHART)/values-$$s.yaml \
			--set oidcVerifier.image.repository=$(DOCKER_REGISTRY)/oidc-verifier --set oidcVerifier.image.tag=$(IMAGE_TAG) \
			-n default --create-namespace --wait --timeout $(HELM_TIMEOUT) \
			--kube-context kind-$$s || exit 1; \
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
		--timeout $(HELM_TIMEOUT) --kube-context kind-$* || exit 1
	kubectl --context kind-$* -n $(ROOK_NS) wait cephobjectstore/s3 --for=jsonpath='{.status.phase}'=Ready --timeout=$(ROOK_TIMEOUT)

# ── Flux / GitOps ────────────────────────────────────────────────────────────
.PHONY: deploy-flux deploy-cd verify-all

deploy-flux:
	@echo "==> Installing Flux controllers on hub"
	flux install --components=source-controller,helm-controller,kustomize-controller \
		--context=kind-$(KIND_HUB) --namespace=flux-system
	@echo "==> Applying Flux bootstrap"
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/bootstrap/flux-setup.yaml
	sleep 3
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/
	@echo "==> Flux ready"

# Same install as deploy-flux; from here Flux takes over the hub HelmReleases.
deploy-cd: deploy-flux
	@echo "==> GitOps enabled — Flux now manages the hub HelmRelease"

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

# ── Validate ─────────────────────────────────────────────────────────────────
.PHONY: validate
validate: ensure-spoke-auth-config
	@echo "==> Running full Chainsaw E2E test suite"
	@mkdir -p $(CHAINSAW_DIR)
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	@for s in $(SPOKES); do kind get kubeconfig --name $$s > $(CHAINSAW_DIR)/kubeconfig-$$s-internal || exit 1; done
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

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean clean-artifacts
clean:
	kind delete cluster --name $(KIND_HUB) 2>/dev/null || true
	@for s in $(ROOK_SPOKES); do docker exec $$s-worker losetup -d $$(docker exec $$s-worker losetup -j $(CEPH_LOOP_IMG) | cut -d: -f1) 2>/dev/null || true; done
	@for s in $(SPOKES); do kind delete cluster --name $$s 2>/dev/null || true; done
	@for s in $(SPOKES); do rm -f $(SPOKE_KC_DIR)/kubeconfig-$$s-internal $(CHAINSAW_DIR)/kubeconfig-$$s-internal; done
	rm -f $(CHAINSAW_DIR)/kubeconfig-hub $(CHAINSAW_DIR)/$(CHAINSAW_REPORT)

clean-artifacts:
	rm -rf $(OUT_DIR) coverage-root.out coverage-vmbc.out coverage-bbc.out

# ── Full loop ────────────────────────────────────────────────────────────────
.PHONY: all
all: lint test build deploy validate
	@echo "==> Full loop complete"

# ── Install helpers ──────────────────────────────────────────────────────────
.PHONY: install-chainsaw install-flux
install-chainsaw:
	go install github.com/kyverno/chainsaw@$(CHAINSAW_VERSION)

install-flux:
	curl -s https://fluxcd.io/install.sh | bash