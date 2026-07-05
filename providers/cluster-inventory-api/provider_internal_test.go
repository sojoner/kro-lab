package clusterinventoryapi

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/cluster"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
)

// fakeCluster is a minimal cluster.Cluster test double. Embedding the nil
// interface means any method beyond GetFieldIndexer panics if called,
// which is fine — this test only exercises indexing.
type fakeCluster struct {
	cluster.Cluster
	indexer *fakeFieldIndexer
}

func (f *fakeCluster) GetFieldIndexer() client.FieldIndexer { return f.indexer }
func (f *fakeCluster) Start(ctx context.Context) error      { <-ctx.Done(); return nil }

type fakeFieldIndexer struct {
	calls int
}

func (f *fakeFieldIndexer) IndexField(ctx context.Context, obj client.Object, field string, extractValue client.IndexerFunc) error {
	f.calls++
	extractValue(obj)
	return nil
}

// TestProvider_IndexField_ReplaysOnFutureEngagement proves an index
// registered before any cluster is engaged gets applied once a cluster is
// later discovered and engaged — the "current and future" contract of
// multicluster.Provider.IndexField. Uses an injected fake cluster factory so
// this stays a hermetic unit test (no live API server needed).
func TestProvider_IndexField_ReplaysOnFutureEngagement(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": ClusterProfileAPIVersion,
		"kind":       ClusterProfileKind,
		"metadata":   map[string]interface{}{"name": "us", "namespace": "default"},
		"spec": map[string]interface{}{
			"clusterManager": map[string]interface{}{"name": "us-fleet-manager"},
		},
	}}
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "us-kubeconfig", Namespace: "default"},
		Data: map[string][]byte{"value": []byte(`apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://127.0.0.1:6443
  name: us
contexts:
- context:
    cluster: us
    user: admin
  name: kind-us
current-context: kind-us
users:
- name: admin
  user:
    token: test-token`)},
	}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	p := New(scheme, hubClient, 10*time.Millisecond)
	indexer := &fakeFieldIndexer{}
	p.newCluster = func(cfg *rest.Config, scheme *runtime.Scheme) (cluster.Cluster, error) {
		return &fakeCluster{indexer: indexer}, nil
	}

	// Register the index before any cluster has been engaged.
	if err := p.IndexField(context.Background(), &corev1.Pod{}, "spec.nodeName", func(client.Object) []string { return nil }); err != nil {
		t.Fatalf("unexpected error registering index: %v", err)
	}
	if indexer.calls != 0 {
		t.Fatalf("expected 0 calls before any cluster is engaged, got %d", indexer.calls)
	}

	aware := &recordingAwareInternal{engaged: make(chan string, 1)}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = p.Run(ctx, &fakeManagerInternal{aware: aware}) }()

	select {
	case <-aware.engaged:
	case <-ctx.Done():
		t.Fatal("timed out waiting for engagement")
	}

	if indexer.calls != 1 {
		t.Errorf("expected the pre-registered index to be replayed once on engagement, got %d calls", indexer.calls)
	}

	// Registering a second index after the cluster is already engaged must
	// apply immediately, not just on future engagements.
	if err := p.IndexField(ctx, &corev1.Pod{}, "status.phase", func(client.Object) []string { return nil }); err != nil {
		t.Fatalf("unexpected error registering second index: %v", err)
	}
	if indexer.calls != 2 {
		t.Errorf("expected IndexField to apply immediately to the already-engaged cluster, got %d calls", indexer.calls)
	}
}

type recordingAwareInternal struct {
	engaged chan string
}

func (r *recordingAwareInternal) Engage(ctx context.Context, name string, cl cluster.Cluster) error {
	r.engaged <- name
	return nil
}

type fakeManagerInternal struct {
	mcmanager.Manager
	aware *recordingAwareInternal
}

func (f *fakeManagerInternal) Engage(ctx context.Context, name string, cl cluster.Cluster) error {
	return f.aware.Engage(ctx, name, cl)
}
