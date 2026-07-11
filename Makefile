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

HUB_CHART          ?= deploy/platform-mvp/chart/hub
US_CHART           ?= deploy/platform-mvp/chart/us
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
TR_DIR             ?= platform-mvp/token-rotator

BC_IMAGE           ?= $(DOCKER_REGISTRY)/binding-controller:$(IMAGE_TAG)
WO_IMAGE           ?= $(DOCKER_REGISTRY)/widget-operator:$(IMAGE_TAG)
OV_IMAGE           ?= $(DOCKER_REGISTRY)/oidc-verifier:$(IMAGE_TAG)
DAP_IMAGE          ?= $(DOCKER_REGISTRY)/dex-auth-plugin:$(IMAGE_TAG)
TR_IMAGE           ?= $(DOCKER_REGISTRY)/token-rotator:$(IMAGE_TAG)

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
	@echo "Test & Lint:"
	@echo "  make test        Run all Go unit tests"
	@echo "  make lint        go vet + gofmt check"
	@echo ""
	@echo "Build & Push:"
	@echo "  make build-images  Build all 5 images in parallel"
	@echo "  make push-images   Push all 5 images to Docker Hub in parallel"
	@echo "  make build-bc / build-wo / build-ov / build-dap / build-tr"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy      Full deployment (clusters + images + us + hub)"
	@echo "  make clusters    Create kind clusters (parallel)"
	@echo "  make deploy-us   Deploy widget-operator + oidc-verifier on us"
	@echo "  make deploy-hub  Deploy full hub stack (Kro + CRDs + Helm)"
	@echo "  make deploy-cd   Enable GitOps (Flux CD) on already-deployed hub"
	@echo "  make verify-all  Full clean-room: clean → deploy → validate → deploy-cd"
	@echo ""
	@echo "Validate:"
	@echo "  make validate    Run full Chainsaw E2E suite"
	@echo ""
	@echo "Clean:"
	@echo "  make clean       Destroy clusters + artifacts"

# ── Test ─────────────────────────────────────────────────────────────────────
.PHONY: test test-root test-bc test-wo test-ov test-dap test-tr test-race test-cover
test: test-root test-bc test-wo test-ov test-dap test-tr
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

test-tr:
	cd $(TR_DIR) && go test ./... -count=1

test-race:
	go test -race ./... -count=1
	cd $(BC_DIR) && go test -race ./... -count=1
	cd $(WO_DIR) && go test -race ./... -count=1
	cd $(OV_DIR) && go test -race ./... -count=1
	cd $(DAP_DIR) && go test -race ./... -count=1
	cd $(TR_DIR) && go test -race ./... -count=1

test-cover:
	go test -coverprofile=coverage-root.out ./...
	cd $(BC_DIR) && go test -coverprofile=../../coverage-bc.out ./...
	cd $(WO_DIR) && go test -coverprofile=../../coverage-wo.out ./...
	cd $(DAP_DIR) && go test -coverprofile=../../coverage-dap.out ./... 2>/dev/null || true
	cd $(TR_DIR) && go test -coverprofile=../../coverage-tr.out ./... 2>/dev/null || true
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
.PHONY: build build-bc build-wo build-ov build-dap build-tr
build: build-bc

build-bc:
	@mkdir -p $(OUT_DIR)
	cd $(BC_DIR) && go build -o ../../$(BC_BIN) .

# ── Docker images (build only) ───────────────────────────────────────────────
.PHONY: build-images build-bc-image build-wo-image build-ov-image build-dap-image build-tr-image

build-images: build-bc-image build-wo-image build-ov-image build-dap-image build-tr-image

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

build-tr-image:
	@echo "==> Building $(TR_IMAGE)"
	docker build -f $(TR_DIR)/Dockerfile -t $(TR_IMAGE) .

# Build all images in parallel
build-images-parallel:
	@echo "==> Building all images in parallel"
	@$(MAKE) --no-print-directory build-bc-image & \
	$(MAKE) --no-print-directory build-wo-image & \
	$(MAKE) --no-print-directory build-ov-image & \
	$(MAKE) --no-print-directory build-dap-image & \
	$(MAKE) --no-print-directory build-tr-image & \
	wait
	@echo "==> All images built"

# ── Docker push (parallel by default) ────────────────────────────────────────
.PHONY: push-images push-bc push-wo push-ov push-dap push-tr

push-images: push-bc push-wo push-ov push-dap push-tr

push-bc:
	docker push $(BC_IMAGE)
push-wo:
	docker push $(WO_IMAGE)
push-ov:
	docker push $(OV_IMAGE)
push-dap:
	docker push $(DAP_IMAGE)
push-tr:
	docker push $(TR_IMAGE)

push-images-parallel:
	@echo "==> Pushing all images to $(DOCKER_REGISTRY)"
	docker push $(BC_IMAGE) & \
	docker push $(WO_IMAGE) & \
	docker push $(OV_IMAGE) & \
	docker push $(DAP_IMAGE) & \
	docker push $(TR_IMAGE) & \
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
	@HUB_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(KIND_HUB)-control-plane 2>/dev/null); \
	if [ -n "$$HUB_IP" ]; then \
		docker exec $(KIND_US)-control-plane sh -c "command -v curl >/dev/null 2>&1 && curl -s --connect-timeout 2 http://$$HUB_IP:6443 >/dev/null 2>&1" 2>/dev/null || true; \
		docker exec $(KIND_US)-control-plane sh -c "command -v wget >/dev/null 2>&1 && wget -q --timeout=2 -O /dev/null http://$$HUB_IP:6443" 2>/dev/null || true; \
		echo "  Cross-cluster reachability OK"; \
	fi
	@echo "==> Clusters ready"

# ── Deploy ───────────────────────────────────────────────────────────────────
.PHONY: deploy deploy-us deploy-hub

deploy: crds
	@echo "==> Building images and creating clusters in parallel"
	$(MAKE) build-images-parallel & \
	$(MAKE) clusters & \
	wait
	$(MAKE) push-images-parallel
	@echo "==> Deploying us + hub in parallel"
	$(MAKE) deploy-us & \
	$(MAKE) deploy-hub & \
	wait
	@echo "==> Platform deploy complete (Flux not yet installed — run 'make deploy-cd' for GitOps)"

deploy-us:
	@echo "==> Deploying widget-operator + oidc-verifier on us"
	kubectl --context kind-$(KIND_US) create namespace default --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install us $(US_CHART) \
		-n default --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_US)
	@echo "  Rolling out widget-operator..."
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/widget-operator --timeout=60s
	@echo "  Rolling out oidc-verifier..."
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/oidc-verifier --timeout=60s
	@echo "==> US spoke deployed"

deploy-hub: crds
	@echo "==> Installing Kro on hub"
	kubectl --context kind-$(KIND_HUB) create namespace kro-system 2>/dev/null || true
	kubectl --context kind-$(KIND_HUB) apply -f $(CRDS_DIR)/kro-core-install-manifests.yaml
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deploy/kro --timeout=2m &
	@echo "  Installing CRDs..."
	kubectl --context kind-$(KIND_HUB) apply -f $(CRDS_DIR)/clusterprofiles-crd.yaml &
	kubectl --context kind-$(KIND_HUB) apply -f $(CRDS_DIR)/cert-manager.crds.yaml &
	kubectl --context kind-$(KIND_HUB) apply -f $(CRDS_DIR)/prometheus-operator-crds.yaml &
	wait
	@echo "  Waiting for Kro CRD..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	@echo "==> Deploying hub (umbrella chart)"
	@if [ ! -f $(BC_INTERNAL_KC) ]; then \
		kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC); \
	fi
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
	@echo "  Creating secrets..."
	kubectl --context kind-$(KIND_HUB) create secret generic us-kubeconfig \
		--from-file=value=$(BC_INTERNAL_KC) \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - &
	kubectl --context kind-$(KIND_HUB) create secret generic binding-controller-dex \
		--from-literal=client-secret=us-spoke-controller-secret-demo \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - &
	kubectl --context kind-$(KIND_HUB) create secret generic token-rotator-dex \
		--from-literal=client-secret=us-spoke-controller-secret-demo \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f - &
	wait
	@echo "  Restarting controllers..."
	kubectl --context kind-$(KIND_HUB) -n default rollout restart deployment/binding-controller &
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout restart deployment/token-rotator 2>/dev/null &
	wait
	kubectl --context kind-$(KIND_HUB) -n default rollout status deployment/binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deployment/token-rotator --timeout=60s 2>/dev/null || true
	@echo "  Enabling Grafana Ingress..."
	helm upgrade hub $(HUB_CHART) -n $(OBS_NS) --timeout 60s \
		--set ingress.host=$(INGRESS_HOST) --set ingress.enabled=true \
		-f $(HUB_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "==> Hub deployed ($(GRAFANA_URL))"

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