package controller

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	RotationsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "token_rotator_rotations_total",
			Help: "Total number of token rotations, partitioned by region and result",
		},
		[]string{"region", "result"},
	)

	RotationErrorsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "token_rotator_rotation_errors_total",
			Help: "Total number of token rotation errors, partitioned by region and error type",
		},
		[]string{"region", "error_type"},
	)

	LastRotationTimestamp = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "token_rotator_last_rotation_timestamp_seconds",
			Help: "Unix timestamp of the last successful token rotation per region",
		},
		[]string{"region"},
	)
)

func init() {
	RotationsTotal.WithLabelValues("init", "success").Inc()
	RotationErrorsTotal.WithLabelValues("init", "init").Inc()
	LastRotationTimestamp.WithLabelValues("init").Set(float64(time.Now().Unix()))
	metrics.Registry.MustRegister(
		RotationsTotal,
		RotationErrorsTotal,
		LastRotationTimestamp,
	)
}