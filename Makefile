# Platform MVP Makefile
# Umbrella Helm charts + Flux CD + Chainsaw E2E
#
# Quick start:
#   make deploy        → create clusters + deploy everything
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
CHAINSAW_IMAGE     ?= chainsaw-runner:local
CHAINSAW_RUNNER_DIR ?= deploy/platform-mvp/observability
CRONJOB_SCHEDULE   ?= "*/2 * * * *"

OUT_DIR            ?= bin
BC_BIN             ?= $(OUT_DIR)/binding-controller
BC_IMAGE           ?= binding-controller:local
BC_DIR             ?= platform-mvp/binding-controller
WO_IMAGE           ?= widget-operator:local
WO_DIR             ?= platform-mvp/widget-operator

FLUX_DIR           ?= deploy/platform-mvp/flux

CERT_MANAGER_VERSION ?= v1.17.1
OIDC_VERIFIER_IMAGE  ?= oidc-verifier:local
OIDC_VERIFIER_DIR    ?= platform-mvp/oidc-verifier

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Platform MVP — build, deploy, validate"
	@echo ""
	@echo "Test & Lint:"
	@echo "  make test        Run all Go unit tests"
	@echo "  make lint        go vet + gofmt check"
	@echo "  make build       Build binding-controller"
	@echo ""
	@echo "  Individual tests:"
	@echo "  make test-bc     Test binding-controller"
	@echo "  make test-wo     Test widget-operator"
	@echo "  make test-ov     Test oidc-verifier"
	@echo "  make test-dap    Test dex-auth-plugin"
	@echo "  make test-tr     Test token-rotator"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy      Full deployment (clusters + us + hub)"
	@echo "  make clusters    Create kind clusters"
	@echo "  make deploy-us   widget-operator on us spoke"
	@echo "  make deploy-hub  Two-stage Helm: infra → full hub stack"
	@echo "  make deploy-flux Install Flux controllers + bootstrap"
	@echo "  make deploy-cd   Enable GitOps (Flux CD) on already-deployed hub"
	@echo "  make verify-all  Full clean-room: clean → deploy → validate → deploy-cd"
	@echo "  make binding-controller-image  Build + load binding-controller image"
	@echo "  make widget-operator-image     Build + load widget-operator image"
	@echo "  make dex-auth-plugin-image     Build + load dex-auth-plugin image"
	@echo "  make token-rotator-image       Build + load token-rotator image"
	@echo "  make chainsaw-runner  Build + load chainsaw-runner image"
	@echo ""
	@echo "Validate:"
	@echo "  make validate    Run full Chainsaw E2E suite (per-test filtering is broken upstream in v0.2.15, so validate-p1-p6/p7-p9 just alias this)"
	@echo ""
	@echo "Grafana:"
	@echo "  make grafana     Port-forward → localhost:3000"
	@echo "  make grafana-url Print dashboard URLs"
	@echo ""
	@echo "Clean:"
	@echo "  make clean       Destroy clusters + artifacts"

# ── Test ─────────────────────────────────────────────────────────────────────
.PHONY: test test-root test-bc test-race test-cover
test: test-root test-bc test-wo test-ov test-dap test-tr
	@echo "==> All unit tests passed"

test-root:
	go test ./... -count=1

test-bc:
	cd platform-mvp/binding-controller && go test ./... -count=1

test-wo:
	cd platform-mvp/widget-operator && go test ./... -count=1

test-ov:
	cd $(OIDC_VERIFIER_DIR) && go test ./... -count=1

test-dap:
	cd platform-mvp/dex-auth-plugin && go test ./... -count=1

test-tr:
	cd platform-mvp/token-rotator && go test ./... -count=1

test-race:
	go test -race ./... -count=1
	cd platform-mvp/binding-controller && go test -race ./... -count=1
	cd platform-mvp/widget-operator && go test -race ./... -count=1
	cd $(OIDC_VERIFIER_DIR) && go test -race ./... -count=1
	cd platform-mvp/dex-auth-plugin && go test -race ./... -count=1
	cd platform-mvp/token-rotator && go test -race ./... -count=1

test-cover:
	go test -coverprofile=coverage-root.out ./...
	cd platform-mvp/binding-controller && go test -coverprofile=../../coverage-bc.out ./...
	cd platform-mvp/widget-operator && go test -coverprofile=../../coverage-wo.out ./...
	cd platform-mvp/dex-auth-plugin && go test -coverprofile=../../coverage-dap.out ./... 2>/dev/null || true
	cd platform-mvp/token-rotator && go test -coverprofile=../../coverage-tr.out ./... 2>/dev/null || true
	@echo "Coverage: coverage-*.out"

# ── Lint ─────────────────────────────────────────────────────────────────────
.PHONY: lint lint-fix tdd-lint
lint:
	@echo "==> go vet + gofmt check"
	go vet ./...
	cd platform-mvp/binding-controller && go vet ./...
	cd platform-mvp/widget-operator && go vet ./...
	cd $(OIDC_VERIFIER_DIR) && go vet ./...
	@if [ -n "$$(gofmt -l .)" ]; then \
		echo "ERROR: files not formatted:"; \
		gofmt -l .; \
		exit 1; \
	fi

lint-fix:
	gofmt -w .
	cd platform-mvp/binding-controller && gofmt -w .
	cd platform-mvp/widget-operator && gofmt -w .
	cd $(OIDC_VERIFIER_DIR) && gofmt -w .
	go vet ./...
	cd platform-mvp/binding-controller && go vet ./...
	cd platform-mvp/widget-operator && go vet ./...
	cd $(OIDC_VERIFIER_DIR) && go vet ./...

tdd-lint: lint

# ── Build ────────────────────────────────────────────────────────────────────
.PHONY: build build-bc
build: build-bc

build-bc:
	@mkdir -p $(OUT_DIR)
	cd platform-mvp/binding-controller && go build -o ../../$(BC_BIN) .

# ── Deploy ───────────────────────────────────────────────────────────────────
.PHONY: deploy clusters deploy-us deploy-hub deploy-flux binding-controller-image widget-operator-image
deploy: clusters deploy-us deploy-hub
	@echo "==> Platform deploy complete (Flux not yet installed — run 'make deploy-cd' for GitOps)"

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

widget-operator-image:
	@echo "==> Building widget-operator image"
	docker build -f $(WO_DIR)/Dockerfile -t $(WO_IMAGE) .
	kind load docker-image $(WO_IMAGE) --name $(KIND_US)

oidc-verifier-image:
	@echo "==> Building oidc-verifier image"
	docker build -f $(OIDC_VERIFIER_DIR)/Dockerfile -t $(OIDC_VERIFIER_IMAGE) .
	kind load docker-image $(OIDC_VERIFIER_IMAGE) --name $(KIND_US)

deploy-us: widget-operator-image oidc-verifier-image
	@echo "==> Deploying widget-operator + oidc-verifier on us"
	kubectl --context kind-$(KIND_US) create namespace default --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install us $(US_CHART) \
		-n default --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--kube-context kind-$(KIND_US)
	@echo "  Restarting widget-operator (picks up freshly-loaded image under its fixed :local tag)"
	kubectl --context kind-$(KIND_US) -n default rollout restart deployment/widget-operator
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/widget-operator --timeout=60s
	@echo "  Restarting oidc-verifier"
	kubectl --context kind-$(KIND_US) -n default rollout restart deployment/oidc-verifier 2>/dev/null || true
	kubectl --context kind-$(KIND_US) -n default rollout status deployment/oidc-verifier --timeout=60s
	@echo "==> Widget operator + oidc-verifier deployed"

binding-controller-image:
	@echo "==> Building binding-controller image"
	docker build -f $(BC_DIR)/Dockerfile -t $(BC_IMAGE) .
	kind load docker-image $(BC_IMAGE) --name $(KIND_HUB)

dex-auth-plugin-image:
	@echo "==> Building dex-auth-plugin image"
	docker build -f platform-mvp/dex-auth-plugin/Dockerfile -t dex-auth-plugin:local .
	kind load docker-image dex-auth-plugin:local --name $(KIND_HUB)

token-rotator-image:
	@echo "==> Building token-rotator image"
	docker build -f platform-mvp/token-rotator/Dockerfile -t token-rotator:local .
	kind load docker-image token-rotator:local --name $(KIND_HUB)

deploy-hub: binding-controller-image dex-auth-plugin-image token-rotator-image
	@echo "==> Installing Kro on hub"
	kubectl --context kind-$(KIND_HUB) create namespace kro-system 2>/dev/null || true
	sleep 2
	kubectl --context kind-$(KIND_HUB) apply -f https://github.com/kubernetes-sigs/kro/releases/download/v0.9.2/kro-core-install-manifests.yaml
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deploy/kro --timeout=2m
	@echo "  Waiting for Kro CRDs..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	@echo "  Installing ClusterProfile CRD..."
	kubectl --context kind-$(KIND_HUB) apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-inventory-api/main/config/crd/bases/multicluster.x-k8s.io_clusterprofiles.yaml
	@echo "  Pre-installing cert-manager CRDs"
	kubectl --context kind-$(KIND_HUB) apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.crds.yaml
	@echo "  Pre-installing prometheus-operator CRDs"
	kubectl --context kind-$(KIND_HUB) apply -f https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.92.1/stripped-down-crds.yaml
	@echo "==> Deploying hub (umbrella chart — single install, webhook ordering handled by Helm)"
	@if [ ! -f $(BC_INTERNAL_KC) ]; then \
		kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC); \
	fi
	kubectl --context kind-$(KIND_HUB) create ns $(OBS_NS) --dry-run=client -o yaml | kubectl apply -f -
	sleep 2
	helm dependency update $(HUB_CHART) > /dev/null
	helm upgrade --install hub $(HUB_CHART) \
		-n $(OBS_NS) --timeout $(HELM_TIMEOUT) \
		--set ingress.host=$(INGRESS_HOST) \
		-f $(HUB_CHART)/e2e-values.yaml \
		--kube-context kind-$(KIND_HUB)
	@echo "  Waiting for core infra..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager --timeout=2m
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-cert-manager-webhook --timeout=2m
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/hub-ingress-nginx-controller --timeout=2m
	@echo "  Waiting for Dex..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deploy/dex --timeout=2m
	@echo "  Creating us-kubeconfig secret..."
	kubectl --context kind-$(KIND_HUB) create secret generic us-kubeconfig \
		--from-file=value=$(BC_INTERNAL_KC) \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f -
	@echo "  Creating Dex client secrets..."
	kubectl --context kind-$(KIND_HUB) create secret generic binding-controller-dex \
		--from-literal=client-secret=us-spoke-controller-secret-demo \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f -
	kubectl --context kind-$(KIND_HUB) create secret generic token-rotator-dex \
		--from-literal=client-secret=us-spoke-controller-secret-demo \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f -
	@echo "  Restarting binding-controller (picks up freshly-loaded image under its fixed :local tag, and the refreshed us-kubeconfig secret)"
	kubectl --context kind-$(KIND_HUB) -n default rollout restart deployment/binding-controller
	kubectl --context kind-$(KIND_HUB) -n default rollout status deployment/binding-controller --timeout=60s
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout restart deployment/token-rotator 2>/dev/null || true
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) rollout status deployment/token-rotator --timeout=60s 2>/dev/null || true
	@echo "==> Hub deployed ($(GRAFANA_URL))"

deploy-flux:
	@echo "==> Installing Flux controllers on hub"
	flux install --components=source-controller,helm-controller,kustomize-controller \
		--context=kind-$(KIND_HUB) --namespace=flux-system
	@echo "==> Applying Flux bootstrap"
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/bootstrap/flux-setup.yaml
	sleep 3
	kubectl --context kind-$(KIND_HUB) apply -f $(FLUX_DIR)/
	@echo "==> Flux ready"

.PHONY: deploy-cd verify-all
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
	make clean
	make deploy
	make validate
	make deploy-cd
	@echo "==> Full validation complete (GitOps enabled)"

# ── Chainsaw runner ──────────────────────────────────────────────────────────
.PHONY: chainsaw-runner
chainsaw-runner:
	docker build -t $(CHAINSAW_IMAGE) -f $(CHAINSAW_RUNNER_DIR)/Dockerfile.chainsaw-runner $(CHAINSAW_RUNNER_DIR)
	kind load docker-image $(CHAINSAW_IMAGE) --name $(KIND_HUB)
	@echo "  Setting up kubeconfig secrets for CronJob..."
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) delete secret kubeconfigs --ignore-not-found
	kubectl --context kind-$(KIND_HUB) -n $(OBS_NS) create secret generic kubeconfigs \
		--from-file=hub="$(HOME)/.kube/config" \
		--from-file=us="$(BC_INTERNAL_KC)" \
		--dry-run=client -o yaml | kubectl apply -f -

# ── Validate ─────────────────────────────────────────────────────────────────
.PHONY: validate validate-p1-p6 validate-p7-p9
validate:
	@echo "==> Running full Chainsaw E2E test suite"
	@mkdir -p $(CHAINSAW_DIR)
	@# Always regenerate — a stale kubeconfig here (e.g. after a cluster was
	@# recreated) fails with an opaque TLS/auth error, not a clear "stale
	@# config" message, so it's cheaper to just always refresh both.
	@# NOTE: kept as "-internal" to match the path baked into the
	@# chainsaw-runner CronJob image (which runs *inside* the hub cluster's
	@# Docker network, where the internal address resolves) — but `make
	@# validate` itself runs from a plain host shell, where "us-control-plane"
	@# is not resolvable, so this must be the host-accessible kubeconfig.
	kind get kubeconfig --name $(KIND_HUB) > $(CHAINSAW_DIR)/kubeconfig-hub
	kind get kubeconfig --name $(KIND_US) > $(CHAINSAW_DIR)/kubeconfig-us-internal
	@# chainsaw only picks up .chainsaw.yaml (with the hub/us cluster mapping)
	@# from its own current directory — passing $(CHAINSAW_DIR) as an argument
	@# without cd'ing into it silently falls back to no-cluster defaults and
	@# every test fails.
	cd $(CHAINSAW_DIR) && chainsaw test . --test-dir tests --fail-fast=false \
		--report-format JSON --report-name $(CHAINSAW_REPORT)

# NOTE: --selector and --include-test-regex are both non-functional for
# per-test filtering in chainsaw v0.2.15 (verified empirically 2026-07-10 —
# every syntax tried matched 0 tests even against exact test names). Until
# that's fixed upstream or worked around, these both just run the full
# suite; use `make validate` directly instead.
validate-p1-p6: validate

validate-p7-p9: validate

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