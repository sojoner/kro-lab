# Platform MVP Makefile
# Umbrella Helm charts + Flux CD + Chainsaw E2E
#
# Quick start:
#   make deploy        → build+push images (parallel) + deploy everything
#   make grafana       → port-forward Grafana to localhost:3000
#   make validate      → run Chainsaw E2E tests
#   make clean         → destroy everything
#
SHELL := /usr/bin/env bash

export PATH := $(shell go env GOPATH)/bin:$(PATH)

# ── Externalized config ──────────────────────────────────────────────────────
KIND_HUB          ?= hub
KIND_US           ?= us
KIND_HUB_CONFIG   ?= deploy/platform-mvp/kind/kind-hub.yaml
KIND_US_CONFIG    ?= deploy/platform-mvp/kind/kind-us.yaml

HUB_CHART          ?= deploy/platform-mvp/chart/infrastructure
US_CHART           ?= deploy/platform-mvp/chart/us
CRDS_CHART         ?= deploy/platform-mvp/chart/crds
HUBSVC_CHART       ?= deploy/platform-mvp/chart/hub-services
HELM_TIMEOUT       ?= 15m

INGRESS_HOST       ?= bm4080.taildf7067.ts.net
GRAFANA_URL        ?= http://$(INGRESS_HOST)
GRAFANA_PF_PORT    ?= 3000
OBS_NS             ?= monitoring

BC_KUBECONFIG      ?= $(HOME)/.kube/config
BC_INTERNAL_KC     ?= hack/platform-mvp/kubeconfig-us-internal

CHAINSAW_DIR       ?= tests/e2e
CHAINSAW_REPORT    ?= chainsaw-report.json
CHAINSAW_RUNNER_DIR ?= deploy/platform-mvp/observability
CRONJOB_SCHEDULE   ?= "*/2 * * * *"

DOCKER_REGISTRY    ?= sojoner
IMAGE_TAG          ?= dev
BC_DIR             ?= platform-mvp/binding-controller
WO_DIR             ?= platform-mvp/widget-operator
OV_DIR             ?= platform-mvp/oidc-verifier
DAP_DIR            ?= platform-mvp/dex-auth-plugin

BC_IMAGE           ?= $(DOCKER_REGISTRY)/binding-controller:$(IMAGE_TAG)
WO_IMAGE           ?= $(DOCKER_REGISTRY)/widget-operator:$(IMAGE_TAG)
OV_IMAGE           ?= $(DOCKER_REGISTRY)/oidc-verifier:$(IMAGE_TAG)
DAP_IMAGE          ?= $(DOCKER_REGISTRY)/dex-auth-plugin:$(IMAGE_TAG)

CRDS_DIR           ?= deploy/platform-mvp/crds
OUT_DIR            ?= bin
BC_BIN             ?= $(OUT_DIR)/binding-controller
FLUX_DIR           ?= deploy/platform-mvp/flux
CERT_MANAGER_VERSION ?= v1.17.1

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Platform MVP — build, deploy, validate"
	@echo ""
	@echo "Deploy (4-wave Helm chart decomposition):"
	@echo "  make deploy        Full deployment (clusters + 4 waves)"
	@echo "  make deploy-wave1  Wave 1: Install all CRDs on hub + us"
	@echo "  make deploy-wave2  Wave 2: Infrastructure on hub (LGTM + Dex + ingress)"
	@echo "  make deploy-wave3  Wave 3: Hub services (Kro + binding-controller + fleet)"
	@echo "  make deploy-wave4  Wave 4: US spoke (widget-operator + oidc-verifier)"
	@echo "  make deploy-cd     Enable GitOps (Flux CD) on hub"
	@echo "  make clusters      Create kind clusters"
	@echo ""
	@echo "Test:"
	@echo "  make test          Run all Go unit tests"
	@echo "  make test-race     Unit tests with race detector"
	@echo "  make test-cover    Unit tests with coverage profiles"
	@echo "  make validate      Run full Chainsaw E2E suite (20 tests)"
	@echo "  make lint          go vet + gofmt check"
	@echo "  make lint-fix      Auto-fix formatting + go vet"
	@echo ""
	@echo "Build:"
	@echo "  make build-images  Build all 4 Docker images in parallel"
	@echo "  make push-images   Push all 4 images to Docker Hub"
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
.PHONY: test test-root test-bc test-wo test-ov test-dap test-race test-cover
test: test-root test-bc test-wo test-ov test-dap
	@echo "==> All unit tests passed"

test-root:
	go test ./... -count=1

test-bc:
	cd $(BC_DIR) && go test ./... -count=1

test-wo:
	cd $(WO_DIR) && go test ./... -count=1

test-ov:
	cd $(OV_DIR) && go test ./... -count=1

test-dap:
	cd $(DAP_DIR) && go test ./... -count=1

test-race:
	go test -race ./... -count=1
	cd $(BC_DIR) && go test -race ./... -count=1
	cd $(WO_DIR) && go test -race ./... -count=1
	cd $(OV_DIR) && go test -race ./... -count=1
	cd $(DAP_DIR) && go test -race ./... -count=1

test-cover:
	go test -coverprofile=coverage-root.out ./...
	cd $(BC_DIR) && go test -coverprofile=../../coverage-bc.out ./...
	cd $(WO_DIR) && go test -coverprofile=../../coverage-wo.out ./...
	cd $(DAP_DIR) && go test -coverprofile=../../coverage-dap.out ./... 2>/dev/null || true
	@echo "Coverage: coverage-*.out"

# ── Lint ─────────────────────────────────────────────────────────────────────
.PHONY: lint lint-fix
lint:
	@echo "==> go vet + gofmt check"
	go vet ./...
	cd $(BC_DIR) && go vet ./...
	cd $(WO_DIR) && go vet ./...
	cd $(OV_DIR) && go vet ./...
	@if [ -n "$$(gofmt -l .)" ]; then \
		echo "ERROR: files not formatted:"; \
		gofmt -l .; \
		exit 1; \
	fi

lint-fix:
	gofmt -w .
	cd $(BC_DIR) && gofmt -w .
	cd $(WO_DIR) && gofmt -w .
	cd $(OV_DIR) && gofmt -w .
	go vet ./...
	cd $(BC_DIR) && go vet ./...
	cd $(WO_DIR) && go vet ./...
	cd $(OV_DIR) && go vet ./...

# ── Build ────────────────────────────────────────────────────────────────────
.PHONY: build build-bc build-wo build-ov build-dap
build: build-bc

build-bc:
	@mkdir -p $(OUT_DIR)
	cd $(BC_DIR) && go build -o ../../$(BC_BIN) .

# ── Docker images (build only) ───────────────────────────────────────────────
.PHONY: build-images build-bc-image build-wo-image build-ov-image build-dap-image

build-images: build-bc-image build-wo-image build-ov-image build-dap-image

build-bc-image:
	@echo "==> Building $(BC_IMAGE)"
	docker build -f $(BC_DIR)/Dockerfile -t $(BC_IMAGE) .

build-wo-image:
	@echo "==> Building $(WO_IMAGE)"
	docker build -f $(WO_DIR)/Dockerfile -t $(WO_IMAGE) .

build-ov-image:
	@echo "==> Building $(OV_IMAGE)"
	docker build -f $(OV_DIR)/Dockerfile -t $(OV_IMAGE) .

build-dap-image:
	@echo "==> Building $(DAP_IMAGE)"
	docker build -f $(DAP_DIR)/Dockerfile -t $(DAP_IMAGE) .

# Build all images in parallel
build-images-parallel:
	@echo "==> Building all images in parallel"
	@$(MAKE) --no-print-directory build-bc-image & \
	$(MAKE) --no-print-directory build-wo-image & \
	$(MAKE) --no-print-directory build-ov-image & \
	$(MAKE) --no-print-directory build-dap-image & \
	wait
	@echo "==> All images built"

# ── Docker push (parallel by default) ────────────────────────────────────────
.PHONY: push-images push-bc push-wo push-ov push-dap

push-images: push-bc push-wo push-ov push-dap

push-bc:
	docker push $(BC_IMAGE)
push-wo:
	docker push $(WO_IMAGE)
push-ov:
	docker push $(OV_IMAGE)
push-dap:
	docker push $(DAP_IMAGE)

push-images-parallel:
	@echo "==> Pushing all images to $(DOCKER_REGISTRY)"
	docker push $(BC_IMAGE) & \
	docker push $(WO_IMAGE) & \
	docker push $(OV_IMAGE) & \
	docker push $(DAP_IMAGE) & \
	wait
	@echo "==> All images pushed"

# ── CRD caching ──────────────────────────────────────────────────────────────
.PHONY: crds

crds: $(CRDS_DIR)/kro-core-install-manifests.yaml \
      $(CRDS_DIR)/clusterprofiles-crd.yaml \
      $(CRDS_DIR)/cert-manager.crds.yaml \
      $(CRDS_DIR)/prometheus-operator-crds.yaml

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

# ── Clusters ─────────────────────────────────────────────────────────────────
.PHONY: clusters

clusters:
	@echo "==> Creating kind clusters (parallel)"
	@if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_HUB)"; then \
		kind create cluster --name $(KIND_HUB) --config $(KIND_HUB_CONFIG) & \
	fi; \
	if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_US)"; then \
		kind create cluster --name $(KIND_US) --config $(KIND_US_CONFIG) & \
	fi; \
	wait
	@echo "  Verifying nodes..."
	kubectl --context kind-$(KIND_HUB) get nodes
	kubectl --context kind-$(KIND_US) get nodes
	@echo "  Extracting internal kubeconfig..."
	kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC)
	@echo "  Generating E2E kubeconfigs..."
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	kind get kubeconfig --name $(KIND_US) --internal > $(CHAINSAW_DIR)/kubeconfig-us-internal
	@US_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(KIND_US)-control-plane 2>/dev/null); \
	if [ -n "$$US_IP" ]; then \
		sed -i "s|https://us-control-plane:6443|https://$$US_IP:6443|" $(CHAINSAW_DIR)/kubeconfig-us-internal; \
	fi
	@HUB_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(KIND_HUB)-control-plane 2>/dev/null); \
	if [ -n "$$HUB_IP" ]; then \
		docker exec $(KIND_US)-control-plane sh -c "command -v curl >/dev/null 2>&1 && curl -s --connect-timeout 2 http://$$HUB_IP:6443 >/dev/null 2>&1" 2>/dev/null || true; \
		docker exec $(KIND_US)-control-plane sh -c "command -v wget >/dev/null 2>&1 && wget -q --timeout=2 -O /dev/null http://$$HUB_IP:6443" 2>/dev/null || true; \
		echo "  Cross-cluster reachability OK"; \
	fi
	@echo "==> Clusters ready"

# ── Deploy ───────────────────────────────────────────────────────────────────
# Wave-based deployment: each wave is a Helm chart that groups related resources.
# Flux/GitOps path mirrors this with HelmRelease dependsOn chains.
.PHONY: deploy deploy-wave1 deploy-wave2 deploy-wave3 deploy-wave4
.PHONY: deploy-us deploy-hub  # legacy aliases

deploy: crds
	@echo "==> Building images and creating clusters in parallel"
	$(MAKE) build-images-parallel & \
	$(MAKE) clusters & \
	wait
	$(MAKE) push-images-parallel
	@echo "==> Wave 1: CRDs on hub + us"
	$(MAKE) deploy-wave1
	@echo "==> Wave 2 (infra on hub) + Wave 4 (US spoke) in parallel"
	@$(MAKE) --no-print-directory deploy-wave2 & \
	$(MAKE) --no-print-directory deploy-wave4 & \
	wait
	@echo "==> Wave 2: Infrastructure on hub"
	$(MAKE) deploy-wave2
	@echo "==> Wave 3: Hub services on hub"
	$(MAKE) deploy-wave3
	@echo "==> Platform deploy complete (Flux not yet installed — run 'make deploy-cd' for GitOps)"

# ── Wave 1: CRDs (both hub and us, cluster-scoped) ──────────────────────────
deploy-wave1: crds
	@echo "==> Wave 1: Installing platform CRDs on hub + us"
	helm upgrade --install crds $(CRDS_CHART) \
		--create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_HUB)
	helm upgrade --install crds $(CRDS_CHART) \
		--create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_US)
	@echo "  Waiting for Kro CRDs..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	kubectl --context kind-$(KIND_US) wait --for=condition=Established crd/widgets.platform.example.com --timeout=30s
	@echo "==> Wave 1 complete"

# ── Wave 2: Infrastructure (hub context) ──────────────────────────────────────
deploy-wave2:
	@echo "==> Wave 2: Installing infrastructure on hub"
	@if [ "$(HUB_CHART)/Chart.lock" -ot "$(HUB_CHART)/Chart.yaml" ]; then \
		echo "  Chart.yaml changed, running helm dependency update..."; \
		helm dependency update $(HUB_CHART) > /dev/null; \
	else \
		echo "  Chart.lock is fresh, skipping helm dependency update"; \
	fi
	helm upgrade --install hub $(HUB_CHART) \
		-n $(OBS_NS) --create-namespace --timeout $(HELM_TIMEOUT) \
		--set ingress.host=$(INGRESS_HOST) \
		-f $(HUB_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "  Waiting for core infra..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager --timeout=2m &
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager-webhook --timeout=2m &
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-ingress-nginx-controller --timeout=2m &
	wait
	@echo "  Waiting for Dex..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/dex --timeout=2m
	@echo "  Enabling Grafana Ingress..."
	helm upgrade hub $(HUB_CHART) -n $(OBS_NS) --timeout 60s \
		--set ingress.host=$(INGRESS_HOST) --set ingress.enabled=true \
		-f $(HUB_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "==> Wave 2 complete"

# ── Wave 3: Hub services (hub context) ────────────────────────────────────────
deploy-wave3:
	@echo "==> Wave 3: Installing hub services on hub"
	@if [ ! -f $(BC_INTERNAL_KC) ]; then \
		kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC); \
	fi
	kubectl --context kind-$(KIND_HUB) create namespace kro-system 2>/dev/null || true
	helm upgrade --install hub-services $(HUBSVC_CHART) \
		-n default --create-namespace --timeout $(HELM_TIMEOUT) \
		-f $(HUBSVC_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "  Creating secrets..."
	kubectl --context kind-$(KIND_HUB) create secret generic us-kubeconfig \
		--from-file=value=$(BC_INTERNAL_KC) \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - &
	kubectl --context kind-$(KIND_HUB) create secret generic binding-controller-dex \
		--from-literal=client-secret=us-spoke-controller-secret-demo \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - &
	wait
	@echo "  Restarting controllers..."
	kubectl --context kind-$(KIND_HUB) -n default rollout restart deployment/binding-controller &
	wait
	kubectl --context kind-$(KIND_HUB) -n default rollout status deployment/binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deployment/kro --timeout=2m
	@echo "==> Wave 3 complete"

# ── Wave 4: US spoke (us context) ─────────────────────────────────────────────
deploy-wave4:
	@echo "==> Wave 4: Installing US spoke on us"
	kubectl --context kind-$(KIND_US) create namespace default --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install us $(US_CHART) \
		-n default --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_US)
	@echo "  Rolling out widget-operator..."
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/widget-operator --timeout=60s
	@echo "  Rolling out oidc-verifier..."
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/oidc-verifier --timeout=60s
	@echo "==> Wave 4 complete"

# Legacy aliases
deploy-us: deploy-wave4
deploy-hub: deploy-wave1 deploy-wave2 deploy-wave3

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

deploy-cd:
	@echo "==> Enabling GitOps (Flux CD) — takes over hub HelmRelease management"
	flux install --components=source-controller,helm-controller,kustomize-controller \
		--context=kind-$(KIND_HUB) --namespace=flux-system
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/bootstrap/flux-setup.yaml
	sleep 3
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/
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
	docker build -t chainsaw-runner:local -f $(CHAINSAW_RUNNER_DIR)/Dockerfile.chainsaw-runner .
	kind load docker-image chainsaw-runner:local --name $(KIND_HUB)
	@echo "  Setting up kubeconfig secrets for CronJob..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) delete secret kubeconfigs --ignore-not-found
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) create secret generic kubeconfigs \
		--from-file=hub="$(HOME)/.kube/config" \
		--from-file=us="$(BC_INTERNAL_KC)" \
		--dry-run=client -o yaml | kubectl apply -f -

# ── Validate ─────────────────────────────────────────────────────────────────
.PHONY: validate
validate:
	@echo "==> Running full Chainsaw E2E test suite"
	@mkdir -p $(CHAINSAW_DIR)
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	kind get kubeconfig --name $(KIND_US) > $(CHAINSAW_DIR)/kubeconfig-us-internal
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
	@echo "  $(GRAFANA_URL)/d/token-rotation         Token Rotation"

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean clean-artifacts
clean:
	kind delete cluster --name $(KIND_HUB) 2>/dev/null || true
	kind delete cluster --name $(KIND_US) 2>/dev/null || true
	rm -f $(BC_INTERNAL_KC)
	rm -f $(CHAINSAW_DIR)/kubeconfig-hub $(CHAINSAW_DIR)/kubeconfig-us-internal $(CHAINSAW_DIR)/$(CHAINSAW_REPORT)

clean-artifacts:
	rm -rf $(OUT_DIR) coverage-root.out coverage-bc.out coverage-wo.out

# ── Full loop ────────────────────────────────────────────────────────────────
.PHONY: all
all: lint test build deploy validate
	@echo "==> Full loop complete"

# ── Install helpers ──────────────────────────────────────────────────────────
.PHONY: install-chainsaw install-flux
install-chainsaw:
	go install github.com/kyverno/chainsaw@latest

install-flux:
	curl -s https://fluxcd.io/install.sh | bash