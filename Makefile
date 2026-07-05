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

LOOP_SIZE          ?= 10G
LOOP_FILE          ?= /var/lib/rook-loopfile

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

FLUX_DIR           ?= deploy/platform-mvp/flux

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
	@echo "Deploy:"
	@echo "  make deploy      Full deployment (clusters + us + hub)"
	@echo "  make clusters    Create kind clusters"
	@echo "  make deploy-us   Rook/Ceph on us spoke"
	@echo "  make deploy-hub  LGTM + ingress + fleet + Kro on hub"
	@echo "  make deploy-flux Install Flux controllers + bootstrap"
	@echo "  make binding-controller-image  Build + load binding-controller image"
	@echo "  make chainsaw-runner  Build + load chainsaw-runner image"
	@echo ""
	@echo "Validate:"
	@echo "  make validate    Run full Chainsaw E2E suite"
	@echo "  make validate-p1-p6  Run platform tests (p1-p6)"
	@echo "  make validate-p7-p9  Run observability tests (p7-p9)"
	@echo ""
	@echo "Grafana:"
	@echo "  make grafana     Port-forward → localhost:3000"
	@echo "  make grafana-url Print dashboard URLs"
	@echo ""
	@echo "Clean:"
	@echo "  make clean       Destroy clusters + artifacts"

# ── Test ─────────────────────────────────────────────────────────────────────
.PHONY: test test-root test-bc test-race test-cover
test: test-root test-bc
	@echo "==> All unit tests passed"

test-root:
	go test ./... -count=1

test-bc:
	cd platform-mvp/binding-controller && go test ./... -count=1

test-race:
	go test -race ./... -count=1
	cd platform-mvp/binding-controller && go test -race ./... -count=1

test-cover:
	go test -coverprofile=coverage-root.out ./...
	cd platform-mvp/binding-controller && go test -coverprofile=../../coverage-bc.out ./...
	@echo "Coverage: coverage-root.out coverage-bc.out"

# ── Lint ─────────────────────────────────────────────────────────────────────
.PHONY: lint lint-fix tdd-lint
lint:
	@echo "==> go vet + gofmt check"
	go vet ./...
	cd platform-mvp/binding-controller && go vet ./...
	@if [ -n "$$(gofmt -l .)" ]; then \
		echo "ERROR: files not formatted:"; \
		gofmt -l .; \
		exit 1; \
	fi

lint-fix:
	gofmt -w .
	cd platform-mvp/binding-controller && gofmt -w .
	go vet ./...
	cd platform-mvp/binding-controller && go vet ./...

tdd-lint: lint

# ── Build ────────────────────────────────────────────────────────────────────
.PHONY: build build-bc
build: build-bc

build-bc:
	@mkdir -p $(OUT_DIR)
	cd platform-mvp/binding-controller && go build -o ../../$(BC_BIN) .

# ── Deploy ───────────────────────────────────────────────────────────────────
.PHONY: deploy clusters deploy-us deploy-hub deploy-flux binding-controller-image
deploy: clusters deploy-us deploy-hub
	@echo "==> Deployment complete"

clusters:
	@echo "==> Creating kind clusters (parallel)"
	@if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_HUB)"; then \
		kind create cluster --name $(KIND_HUB) --config $(KIND_HUB_CONFIG) & \
	fi
	@if ! kind get clusters 2>/dev/null | grep -qx "$(KIND_US)"; then \
		kind create cluster --name $(KIND_US) --config $(KIND_US_CONFIG) & \
	fi
	@wait
	@echo "  Verifying nodes..."
	kubectl --context kind-$(KIND_HUB) get nodes
	kubectl --context kind-$(KIND_US) get nodes
	@echo "  Extracting internal kubeconfig..."
	kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC)
	@HUB_IP=$$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-$(KIND_HUB)-control-plane); \
	docker exec kind-$(KIND_US)-control-plane ping -c1 "$$HUB_IP" 2>/dev/null && echo "  Cross-cluster reachability OK"
	@echo "==> Clusters ready"

deploy-us:
	@echo "==> Attaching loop devices to us workers"
	@WORKERS=$$(docker ps --filter "name=$(KIND_US)-worker" --format '{{.Names}}'); \
	for node in $$WORKERS; do \
		docker exec "$$node" truncate -s $(LOOP_SIZE) $(LOOP_FILE); \
		docker exec "$$node" losetup -f $(LOOP_FILE) 2>/dev/null || true; \
	done
	@echo "==> Deploying Rook operator"
	helm dependency update $(US_CHART) > /dev/null
	kubectl --context kind-$(KIND_US) create namespace rook-ceph --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install rook-operator $(US_CHART) \
		-n rook-ceph --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--set rook-ceph-cluster.enabled=false \
		--kube-context kind-$(KIND_US)
	@echo "  Waiting for Rook CRDs..."
	kubectl --context kind-$(KIND_US) wait --for=condition=Established crd/cephclusters.ceph.rook.io --timeout=60s
	@echo "==> Deploying CephCluster + ObjectStore"
	helm upgrade --install rook-cluster $(US_CHART) \
		-n rook-ceph --wait --timeout $(HELM_TIMEOUT) \
		--set rook-ceph.enabled=false \
		--kube-context kind-$(KIND_US)
	@echo "==> Rook/Ceph deployed"

binding-controller-image:
	@echo "==> Building binding-controller image"
	docker build -f $(BC_DIR)/Dockerfile -t $(BC_IMAGE) .
	kind load docker-image $(BC_IMAGE) --name $(KIND_HUB)

deploy-hub: binding-controller-image
	@echo "==> Installing Kro on hub"
	kubectl --context kind-$(KIND_HUB) create namespace kro-system 2>/dev/null || true
	sleep 2
	kubectl --context kind-$(KIND_HUB) apply -f https://github.com/kubernetes-sigs/kro/releases/download/v0.9.2/kro-core-install-manifests.yaml
	kubectl --context kind-$(KIND_HUB) -n kro-system rollout status deploy/kro --timeout=2m
	@echo "  Waiting for Kro CRDs..."
	kubectl --context kind-$(KIND_HUB) wait --for=condition=Established crd/resourcegraphdefinitions.kro.run --timeout=30s
	@echo "  Installing ClusterProfile CRD..."
	kubectl --context kind-$(KIND_HUB) apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-inventory-api/main/config/crd/bases/multicluster.x-k8s.io_clusterprofiles.yaml
	@echo "==> Deploying hub (umbrella chart)"
	@if [ ! -f $(BC_INTERNAL_KC) ]; then \
		kind get kubeconfig --name $(KIND_US) --internal > $(BC_INTERNAL_KC); \
	fi
	helm dependency update $(HUB_CHART) > /dev/null
	helm upgrade --install hub $(HUB_CHART) \
		-n $(OBS_NS) --create-namespace --wait --timeout $(HELM_TIMEOUT) \
		--set ingress.host=$(INGRESS_HOST) \
		--kube-context kind-$(KIND_HUB)
	@echo "  Creating us-kubeconfig secret..."
	kubectl --context kind-$(KIND_HUB) create secret generic us-kubeconfig \
		--from-file=value=$(BC_INTERNAL_KC) \
		--dry-run=client -o yaml | kubectl --context kind-$(KIND_HUB) apply -f -
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
	@if [ ! -f $(CHAINSAW_DIR)/kubeconfig-hub ]; then cp "$(HOME)/.kube/config" $(CHAINSAW_DIR)/kubeconfig-hub; fi
	@if [ ! -f $(CHAINSAW_DIR)/kubeconfig-us-internal ]; then cp $(BC_INTERNAL_KC) $(CHAINSAW_DIR)/kubeconfig-us-internal; fi
	chainsaw test $(CHAINSAW_DIR) --report-format JSON --report-name $(CHAINSAW_REPORT)

validate-p1-p6:
	chainsaw test $(CHAINSAW_DIR) --test-dir $(CHAINSAW_DIR)/tests \
		--selector 'test=01-hub-cluster-ready,test=02-us-cluster-ready,test=03-rook-ceph-healthy,test=04-fleet-registration,test=05-kro-globalbucket,test=06-binding-controller'

validate-p7-p9:
	chainsaw test $(CHAINSAW_DIR) --test-dir $(CHAINSAW_DIR)/tests \
		--selector 'test=07-observability-stack,test=08-chainsaw-cronjob,test=09-ingress-log-shipping'

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
	@echo "  $(GRAFANA_URL)/d/controller-rook-recon  Controller + Rook Reconciliation"
	@echo "  $(GRAFANA_URL)/d/controller-deep-dive   Controller Deep Dive"

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean clean-artifacts
clean:
	kind delete cluster --name $(KIND_HUB) 2>/dev/null || true
	kind delete cluster --name $(KIND_US) 2>/dev/null || true
	rm -f $(BC_INTERNAL_KC)
	rm -f $(CHAINSAW_DIR)/kubeconfig-hub $(CHAINSAW_DIR)/kubeconfig-us-internal $(CHAINSAW_REPORT)

clean-artifacts:
	rm -rf $(OUT_DIR) coverage-root.out coverage-bc.out

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