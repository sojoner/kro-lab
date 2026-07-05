package clusterinventoryapi

import (
	"context"
	"fmt"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/cluster"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

const (
	ClusterProfileAPIVersion = "multicluster.x-k8s.io/v1alpha1"
	ClusterProfileKind       = "ClusterProfile"

	// KubeconfigSecretSuffix is appended to a ClusterProfile's name to find
	// its kubeconfig Secret in the same namespace. The real ClusterProfile
	// CRD's spec is a strict schema (clusterManager/displayName only, no
	// room for a custom secretRef field), so the kubeconfig is located by
	// naming convention instead of a spec reference.
	KubeconfigSecretSuffix = "-kubeconfig"
)

var ClusterProfileGVK = schema.FromAPIVersionAndKind(ClusterProfileAPIVersion, ClusterProfileKind)

var _ multicluster.Provider = (*Provider)(nil)

// indexRegistration records an IndexField call so it can be replayed against
// clusters engaged after the call was made, per the Provider.IndexField
// contract ("current and future" clusters).
type indexRegistration struct {
	obj          client.Object
	field        string
	extractValue client.IndexerFunc
}

// Provider discovers spoke clusters from ClusterProfile objects on the hub
// and engages the multicluster-runtime manager with a real cluster.Cluster
// for each one it finds.
type Provider struct {
	scheme       *runtime.Scheme
	hubClient    client.Client
	pollInterval time.Duration
	newCluster   func(cfg *rest.Config, scheme *runtime.Scheme) (cluster.Cluster, error)

	mu       sync.RWMutex
	clusters map[string]cluster.Cluster
	indexes  []indexRegistration
}

// New creates a Provider that polls ClusterProfile objects on the hub every
// pollInterval to discover spoke clusters.
func New(scheme *runtime.Scheme, hubClient client.Client, pollInterval time.Duration) *Provider {
	return &Provider{
		scheme:       scheme,
		hubClient:    hubClient,
		pollInterval: pollInterval,
		newCluster:   newRealCluster,
		clusters:     map[string]cluster.Cluster{},
	}
}

func newRealCluster(cfg *rest.Config, scheme *runtime.Scheme) (cluster.Cluster, error) {
	return cluster.New(cfg, func(o *cluster.Options) {
		o.Scheme = scheme
	})
}

// Get returns a cluster for the given identifying cluster name. Returns
// ErrClusterNotFound if the cluster has not been engaged.
func (p *Provider) Get(_ context.Context, clusterName string) (cluster.Cluster, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if cl, ok := p.clusters[clusterName]; ok {
		return cl, nil
	}
	return nil, multicluster.ErrClusterNotFound
}

// IndexField indexes the given object by the given field on all engaged
// clusters, current and future.
func (p *Provider) IndexField(ctx context.Context, obj client.Object, field string, extractValue client.IndexerFunc) error {
	p.mu.Lock()
	p.indexes = append(p.indexes, indexRegistration{obj: obj, field: field, extractValue: extractValue})
	clusters := make([]cluster.Cluster, 0, len(p.clusters))
	for _, cl := range p.clusters {
		clusters = append(clusters, cl)
	}
	p.mu.Unlock()

	for _, cl := range clusters {
		if err := cl.GetFieldIndexer().IndexField(ctx, obj, field, extractValue); err != nil {
			return err
		}
	}
	return nil
}

// Run starts the provider and blocks, polling ClusterProfile objects on the
// hub and engaging mgr with a cluster.Cluster for each one discovered.
func (p *Provider) Run(ctx context.Context, mgr mcmanager.Manager) error {
	p.discover(ctx, mgr)

	ticker := time.NewTicker(p.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			p.discover(ctx, mgr)
		}
	}
}

func (p *Provider) discover(ctx context.Context, mgr mcmanager.Manager) {
	cps := &unstructured.UnstructuredList{}
	cps.SetGroupVersionKind(ClusterProfileGVK)
	if err := p.hubClient.List(ctx, cps); err != nil {
		return
	}

	for _, cp := range cps.Items {
		name := cp.GetName()

		p.mu.RLock()
		_, engaged := p.clusters[name]
		p.mu.RUnlock()
		if engaged {
			continue
		}

		cl, err := p.clusterFromClusterProfile(ctx, &cp)
		if err != nil {
			continue
		}

		go func() { _ = cl.Start(ctx) }()

		p.mu.Lock()
		p.clusters[name] = cl
		indexes := make([]indexRegistration, len(p.indexes))
		copy(indexes, p.indexes)
		p.mu.Unlock()

		for _, idx := range indexes {
			_ = cl.GetFieldIndexer().IndexField(ctx, idx.obj, idx.field, idx.extractValue)
		}

		if err := mgr.Engage(ctx, name, cl); err != nil {
			p.mu.Lock()
			delete(p.clusters, name)
			p.mu.Unlock()
		}
	}
}

func (p *Provider) clusterFromClusterProfile(ctx context.Context, cp *unstructured.Unstructured) (cluster.Cluster, error) {
	secretName := cp.GetName() + KubeconfigSecretSuffix
	secretNamespace := cp.GetNamespace()

	secret := &corev1.Secret{}
	if err := p.hubClient.Get(ctx, types.NamespacedName{
		Name:      secretName,
		Namespace: secretNamespace,
	}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, multicluster.ErrClusterNotFound
		}
		return nil, fmt.Errorf("getting kubeconfig secret %s/%s: %w", secretNamespace, secretName, err)
	}

	kubeconfigBytes, ok := secret.Data["value"]
	if !ok {
		return nil, fmt.Errorf("kubeconfig secret %s/%s missing 'value' key", secretNamespace, secretName)
	}

	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfigBytes)
	if err != nil {
		return nil, fmt.Errorf("parsing kubeconfig for cluster %s: %w", cp.GetName(), err)
	}

	cl, err := p.newCluster(cfg, p.scheme)
	if err != nil {
		return nil, fmt.Errorf("creating cluster for %s: %w", cp.GetName(), err)
	}
	return cl, nil
}
