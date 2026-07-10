# 07-observability Spec
# RED phase — tests before implementation

## Goal

Deploy LGTM (Loki, Grafana, Tempo-optional, Mimir-unnecessary — Prometheus for metrics)
observability stack on hub cluster with three dashboards and continuous in-cluster
Chainsaw execution feeding clean telemetry from within the cluster.

## What

1. kube-prometheus-stack on hub `monitoring` namespace (Prometheus + Grafana + kube-state-metrics)
2. Loki single-binary on hub for Chainsaw JSON report ingestion + controller logs
3. Chainsaw CronJob running inside hub, pushing results to Loki every 5m
4. Three Grafana dashboards deployed as ConfigMaps:
   - Cluster Fitness (hub + us side-by-side)
   - Chainsaw Test Results (pass/fail, duration, history)
   - Controller Deep Dive (reconcile rate, errors, latency)

## Acceptance Criteria

1. Prometheus StatefulSet/Deployment exists in monitoring namespace
2. Grafana Deployment exists, `/api/health` returns 200
3. Loki Deployment exists, `/ready` returns 200
4. ServiceMonitor for binding-controller exists (scrapes :8080/metrics)
5. Chainsaw CronJob exists in monitoring namespace, runs every 5m
6. After one CronJob execution, Chainsaw results appear in Loki (queryable)
7. Grafana dashboards load without error
8. Chainsaw tests 07 + 08 pass from `tests/e2e/`