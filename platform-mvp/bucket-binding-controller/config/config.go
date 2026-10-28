// Package config turns command-line flags into a validated Config. Helm
// values are the source of truth; the flag defaults only keep a bare
// `bucket-binding-controller` runnable.
package config

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type Config struct {
	HubKubeconfig    string
	ClusterSelector  map[string]string // ClusterProfile labels a spoke must carry to be engaged
	RegionLabel      string            // ClusterProfile label naming the region a spoke serves
	StorageClass     string            // StorageClass of the claims (Rook's bucket provisioner)
	RequeueInterval  time.Duration     // drift-correction and Unschedulable retry period
	CleanupInterval  time.Duration     // how often a deleting request re-checks its claim
	PollInterval     time.Duration     // how often the provider re-lists ClusterProfiles
	DefaultNamespace string            // spoke namespace when a request has no tenant label
	MetricsAddr      string            // metrics listener address
}

func Parse(args []string) (Config, error) {
	fs := flag.NewFlagSet("bucket-binding-controller", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	var c Config
	var selector string
	fs.StringVar(&c.HubKubeconfig, "hub-kubeconfig", "", "Path to hub kubeconfig (empty = in-cluster)")
	fs.StringVar(&selector, "cluster-selector", "platform.example.com/offers-object-storage=true", "Comma-separated key=value ClusterProfile labels; empty engages every cluster")
	fs.StringVar(&c.RegionLabel, "region-label", "platform.example.com/region", "ClusterProfile label naming the region a spoke serves")
	fs.StringVar(&c.StorageClass, "storage-class", "ceph-bucket", "StorageClass of the ObjectBucketClaims")
	fs.DurationVar(&c.RequeueInterval, "requeue-interval", 30*time.Second, "Requeue period for drift correction and unschedulable requests")
	fs.DurationVar(&c.CleanupInterval, "cleanup-interval", 5*time.Second, "Re-check period while a deleted request waits for its claim to go")
	fs.DurationVar(&c.PollInterval, "poll-interval", 10*time.Second, "ClusterProfile discovery period")
	fs.StringVar(&c.DefaultNamespace, "default-namespace", "default", "Spoke namespace for requests without a tenant label")
	fs.StringVar(&c.MetricsAddr, "metrics-bind-address", ":8080", "Address of the metrics endpoint")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}

	var err error
	if c.ClusterSelector, err = parseSelector(selector); err != nil {
		return Config{}, err
	}
	switch {
	case c.RegionLabel == "":
		return Config{}, fmt.Errorf("region-label must not be empty")
	case c.StorageClass == "":
		return Config{}, fmt.Errorf("storage-class must not be empty")
	case c.RequeueInterval <= 0:
		return Config{}, fmt.Errorf("requeue-interval must be positive")
	case c.CleanupInterval <= 0:
		return Config{}, fmt.Errorf("cleanup-interval must be positive")
	case c.PollInterval <= 0:
		return Config{}, fmt.Errorf("poll-interval must be positive")
	case c.DefaultNamespace == "":
		return Config{}, fmt.Errorf("default-namespace must not be empty")
	}
	return c, nil
}

func parseSelector(s string) (map[string]string, error) {
	selector := map[string]string{}
	if s == "" {
		return selector, nil
	}
	for _, pair := range strings.Split(s, ",") {
		k, v, ok := strings.Cut(pair, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("invalid selector entry %q, want key=value", pair)
		}
		selector[k] = v
	}
	return selector, nil
}
