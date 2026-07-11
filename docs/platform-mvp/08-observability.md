# Phase 8 — Observability Stack

The observability layer provides metrics, logging, dashboards, and continuous compliance validation on the hub cluster. It is deployed as part of the hub Helm chart with Flux-managed Helm sub-charts for Prometheus, Loki, and ingress-nginx.

---

## Component Architecture

```mermaid
graph TB
    subgraph Hub["Hub Cluster"]
        subgraph Metrics
            PROM["Prometheus<br/>2d retention<br/>15s scrape"]
            SM_BC["ServiceMonitor<br/>binding-controller"]
            SM_TR["ServiceMonitor<br/>token-rotator"]
            NE["node-exporter<br/>DaemonSet"]
            KSM["kube-state-metrics"]
        end

        subgraph Logs
            EVEXP["Event Exporter<br/>K8s events → Loki"]
            LOKI["Loki<br/>SingleBinary<br/>filesystem storage"]
        end

        subgraph Dashboards
            GRAF["Grafana<br/>admin/admin<br/>4 custom dashboards"]
        end

        subgraph Compliance
            CRON["Chainsaw CronJob<br/>every 2m"]
        end

        subgraph Ingress
            NGINX["nginx-ingress<br/>dex + grafana routes"]
        end
    end

    subgraph Spoke["Spoke (kind-us)"]
        OV["OIDC Verifier<br/>AUDIT logs → stdout"]
    end

    SM_BC -->|"scrape :8080"| PROM
    SM_TR -->|"scrape :8080"| PROM
    NE -->|"node metrics"| PROM
    KSM -->|"resource metrics"| PROM
    PROM --> GRAF
    EVEXP -->|"push structured events"| LOKI
    LOKI --> GRAF
    CRON -->|"push test results"| LOKI
    CRON -->|"run chainsaw tests"| Hub
    CRON -->|"run chainsaw tests"| Spoke
    OV -.->|"stdout AUDIT → Loki via event-exporter"| EVEXP
```

## Prometheus

Deployed via `kube-prometheus-stack` Helm chart (`deploy/platform-mvp/observability/kube-prometheus-stack-values.yaml`):

| Setting | Value |
|---------|-------|
| Replicas | 1 |
| Retention | 2 days |
| Scrape interval | 30s |
| ServiceMonitor selector | `{}` (all ServiceMonitors) |
| Storage | Empty (no PVC) |

### ServiceMonitors

Two custom ServiceMonitors in `chart/hub/templates/servicemonitors.yaml`:

- **binding-controller** (lines 4-18): scrapes `:8080/metrics` every 15s
- **token-rotator** (lines 21-36): scrapes `:8080/metrics` every 15s

Plus kube-prometheus-stack's built-in ServiceMonitors for core Kubernetes components.

## Grafana

Deployed as part of `kube-prometheus-stack`:

- **Credentials**: `admin` / `admin` (values.yaml lines 29-31)
- **Loki datasource**: Pre-configured at `http://loki.monitoring:3100` (values.yaml lines 40-49)
- **Custom dashboards** (mounted from ConfigMaps via `chart/hub/templates/dashboards.yaml`):

| Dashboard | ConfigMap | Purpose |
|-----------|-----------|---------|
| Chainsaw Results | `grafana-dashboard-chainsaw-results` | E2E test pass/fail trends over time |
| Cluster Fitness | `grafana-dashboard-cluster-fitness` | Node readiness, pod health, resource utilization |
| Controller Deep Dive | `grafana-dashboard-controller-deep-dive` | Binding controller reconcile latency, regional distribution |
| Token Rotation | `grafana-dashboard-token-rotation` | Rotation frequency, success rate, last rotation timestamp |

## Loki

Deployed via `grafana/loki` Helm chart (`deploy/platform-mvp/observability/loki-values.yaml`):

| Setting | Value |
|---------|-------|
| Mode | SingleBinary |
| Storage | Filesystem (`/var/loki`) |
| Persistence | Disabled (kind dev) |
| Schema | TSDB v13, 24h index period |
| Auth | Disabled |

### Event Exporter — Log Shipping

The `kubernetes-event-exporter` (`chart/hub/templates/event-exporter.yaml:21`) replaces promtail for Kubernetes events. It watches all namespaces and sends structured events to Loki:

```yaml
# Lines 41-62: Loki receiver config
receivers:
  - name: loki
    loki:
      url: http://loki.monitoring:3100/loki/api/v1/push
      labels:
        involved_kind: "{{ .InvolvedObject.Kind }}"
        involved_name: "{{ .InvolvedObject.Name }}"
        reason: "{{ .Reason }}"
        type: "{{ .Type }}"
        namespace: "{{ .Namespace }}"
```

**Note on promtail**: The architecture originally planned to use `promtail` for log shipping (including oidc-verifier AUDIT logs), but the production deployment uses `kubernetes-event-exporter` for Kubernetes event routing to Loki. The oidc-verifier's structured `AUDIT` log lines to stdout are not currently shipped to Loki — this is a known gap for future iteration. See `deploy/platform-mvp/observability/promtail-values.yaml` for the promtail configuration that would be used when this is enabled.

## Ingress (nginx)

Deployed via `ingress-nginx/ingress-nginx` Helm chart (`deploy/platform-mvp/observability/nginx-ingress-values.yaml`):

- **HostPort** (kind): 80 + 443 on hub control-plane node
- **Routes**: `dex.example.com` → Dex service, `grafana.example.com` → Grafana service
- **TLS**: cert-manager self-signed certificates (dev only)

```mermaid
graph LR
    subgraph External
        USER["External<br/>Tailscale Funnel"]
    end

    subgraph Hub
        NGINX["nginx-ingress<br/>hostPort 80/443"]
        DEX["Dex :5556"]
        GRAF["Grafana :80"]
    end

    USER -->|"dex.bm4080.taildf7067.ts.net"| NGINX
    USER -->|"grafana.bm4080.taildf7067.ts.net"| NGINX
    NGINX -->|"Host: dex"| DEX
    NGINX -->|"Host: grafana"| GRAF
```

## Chainsaw CronJob — Continuous Compliance

A `CronJob` (`chart/hub/templates/chainsaw-cronjob.yaml:1-84`) runs the full E2E test suite every 2 minutes against both clusters:

```mermaid
sequenceDiagram
    participant CronJob as Chainsaw CronJob
    participant Runner as runner.sh
    participant Loki as Loki
    participant Hub as kind-hub
    participant Spoke as kind-us

    Note over CronJob: Every 2 minutes
    CronJob->>Runner: Start test run
    Runner->>Runner: Copy kubeconfigs<br/>Generate .chainsaw.yaml
    Runner->>Hub: chainsaw test (hub + us)
    Hub-->>Runner: test results (JSON)
    Runner->>Spoke: chainsaw test (hub + us)
    Spoke-->>Runner: test results (JSON)
    Runner->>Loki: POST /loki/api/v1/push<br/>chainsaw_results label set
```

**Runner details** (`deploy/platform-mvp/observability/runner.sh`):

1. Copies `hub` and `us-internal` kubeconfigs to working dir (lines 35-36)
2. Generates `.chainsaw.yaml` with multi-cluster config (lines 38-62)
3. Runs `chainsaw test` with JSON report output (lines 67-75)
4. Pushes results to Loki as structured log entries (lines 98-110)

**Docker image** (`Dockerfile.chainsaw-runner`): Alpine 3.21 with `kubectl`, `chainsaw`, `curl`, `jq`, `bash`, `coreutils`, `sed`.

## Dashboard Data Flow

```mermaid
sequenceDiagram
    participant GRAF as Grafana
    participant PROM as Prometheus
    participant LOKI as Loki
    participant BC as Binding Controller
    participant TR as Token Rotator

    Note over GRAF: Cluster Fitness Dashboard
    GRAF->>PROM: kube_node_status_condition{condition="Ready"}
    PROM-->>GRAF: node readiness

    Note over GRAF: Controller Deep Dive
    GRAF->>PROM: binding_controller_roundtrip_seconds
    PROM-->>GRAF: reconcile latency histogram

    Note over GRAF: Token Rotation Dashboard
    GRAF->>PROM: token_rotator_rotations_total{result="success"}
    PROM-->>GRAF: rotation count by region
    GRAF->>PROM: token_rotator_last_rotation_timestamp_seconds
    PROM-->>GRAF: last rotation time

    Note over GRAF: Chainsaw Results
    GRAF->>LOKI: {job="chainsaw-runner"}
    LOKI-->>GRAF: test run JSON entries
```

---

## Testing

| Test | What It Validates |
|------|-------------------|
| `07-observability-stack` | Prometheus, Grafana, Loki pods are Ready; all ServiceMonitors exist |
| `08-chainsaw-cronjob` | CronJob exists, is scheduled, previous job completed |
| `09-ingress-log-shipping` | Dex + Grafana ingresses exist with TLS; Event Exporter routes events to Loki |
| `12-dashboard-metrics` | Prometheus returns data for binding-controller and token-rotator metrics |
| `15-dashboard-data` | Grafana dashboards render data for cluster-fitness, controller-deep-dive, and token-rotation panels via port-forward queries to Prometheus |

## Key Files

| File | Purpose |
|------|---------|
| `observability/kube-prometheus-stack-values.yaml` | Prometheus + Grafana Helm values |
| `observability/loki-values.yaml` | Loki SingleBinary Helm values |
| `observability/nginx-ingress-values.yaml` | nginx-ingress Helm values |
| `observability/runner.sh` | Chainsaw runner entrypoint |
| `observability/Dockerfile.chainsaw-runner` | Runner image build |
| `chart/hub/templates/servicemonitors.yaml` | ServiceMonitor CRDs for binding-controller + token-rotator |
| `chart/hub/templates/event-exporter.yaml` | Event Exporter Deployment + ConfigMap |
| `chart/hub/templates/chainsaw-cronjob.yaml` | Chainsaw CronJob |
| `chart/hub/templates/dashboards.yaml` | Grafana dashboard ConfigMaps |
| `dashboards/*.json` | Dashboard JSON definitions |