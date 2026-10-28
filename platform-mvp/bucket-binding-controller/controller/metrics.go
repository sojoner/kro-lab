package controller

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// ReconcileTotal counts RegionalBucketRequest reconciles by tenant, region
// and outcome. Dashboards and the e2e suite read it.
var ReconcileTotal = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name: "bucket_binding_controller_reconcile_total",
		Help: "Total number of RegionalBucketRequest reconciles, partitioned by tenant and region",
	},
	[]string{"tenant_id", "region", "result"},
)

func init() {
	// A counter vector exposes nothing until it has a child; this one makes the
	// series scrapeable before the first real reconcile.
	ReconcileTotal.WithLabelValues("init", "none", "success").Inc()
	metrics.Registry.MustRegister(ReconcileTotal)
}
