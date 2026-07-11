package clusterinventoryapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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

// fakeCluster is a minimal cluster.Cluster test double.
type fakeCluster struct {
	cluster.Cluster
	indexer  *fakeFieldIndexer
	started  chan struct{}
	stopped  chan struct{}
}

func (f *fakeCluster) GetFieldIndexer() client.FieldIndexer { return f.indexer }
func (f *fakeCluster) Start(ctx context.Context) error {
	close(f.started)
	<-ctx.Done()
	close(f.stopped)
	return nil
}

type fakeFieldIndexer struct {
	calls int
}

func (f *fakeFieldIndexer) IndexField(ctx context.Context, obj client.Object, field string, extractValue client.IndexerFunc) error {
	f.calls++
	extractValue(obj)
	return nil
}

// fakeClusterFactory creates clusters that track start/stop lifecycle.
type fakeClusterFactory struct {
	clusters []*fakeCluster
}

func (f *fakeClusterFactory) newCluster(cfg *rest.Config, scheme *runtime.Scheme) (cluster.Cluster, error) {
	fc := &fakeCluster{indexer: &fakeFieldIndexer{}, started: make(chan struct{}), stopped: make(chan struct{})}
	f.clusters = append(f.clusters, fc)
	return fc, nil
}

const testKubeconfigA = `apiVersion: v1
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
    token: token-a`

const testKubeconfigB = `apiVersion: v1
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
    token: token-b-rotated`

func hashKubeconfig(data string) string {
	h := sha256.New()
	h.Write([]byte(data))
	return hex.EncodeToString(h.Sum(nil))
}

// ── Kubeconfig change detection ──────────────────────────────────

func TestProvider_KubeconfigUnchanged_SkipsReengage(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{"apiVersion": ClusterProfileAPIVersion, "kind": ClusterProfileKind, "metadata": map[string]interface{}{"name": "us", "namespace": "default"}, "spec": map[string]interface{}{"clusterManager": map[string]interface{}{"name": "us-fleet-manager"}}}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "us" + KubeconfigSecretSuffix, Namespace: "default"}, Data: map[string][]byte{"value": []byte(testKubeconfigA)}}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	factory := &fakeClusterFactory{}
	p := New(scheme, hubClient, 10*time.Millisecond)
	p.newCluster = factory.newCluster

	aware := &recordingAwareInternal{engaged: make(chan string, 5)}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = p.Run(ctx, &fakeManagerInternal{aware: aware}) }()

	// First engagement
	select {
	case name := <-aware.engaged:
		if name != "us" {
			t.Fatalf("expected us, got %s", name)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for first engagement")
	}

	// Wait for another discovery cycle — kubeconfig unchanged
	select {
	case <-aware.engaged:
		t.Fatal("unexpected re-engagement: kubeconfig should not have changed")
	case <-time.After(200 * time.Millisecond):
		// expected — no re-engagement
	}

	if len(factory.clusters) != 1 {
		t.Errorf("expected 1 cluster created, got %d", len(factory.clusters))
	}
}

func TestProvider_KubeconfigChange_ReengagesCluster(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{"apiVersion": ClusterProfileAPIVersion, "kind": ClusterProfileKind, "metadata": map[string]interface{}{"name": "us", "namespace": "default"}, "spec": map[string]interface{}{"clusterManager": map[string]interface{}{"name": "us-fleet-manager"}}}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "us" + KubeconfigSecretSuffix, Namespace: "default"}, Data: map[string][]byte{"value": []byte(testKubeconfigA)}}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	factory := &fakeClusterFactory{}
	p := New(scheme, hubClient, 10*time.Millisecond)
	p.newCluster = factory.newCluster

	aware := &recordingAwareInternal{engaged: make(chan string, 5)}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() { _ = p.Run(ctx, &fakeManagerInternal{aware: aware}) }()

	// First engagement
	select {
	case <-aware.engaged:
	case <-ctx.Done():
		t.Fatal("timed out waiting for first engagement")
	}

	if len(factory.clusters) != 1 {
		t.Fatalf("expected 1 cluster after first engage, got %d", len(factory.clusters))
	}
	oldCluster := factory.clusters[0]

	// Update the secret with new kubeconfig
	updatedSecret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "us" + KubeconfigSecretSuffix, Namespace: "default"}, Data: map[string][]byte{"value": []byte(testKubeconfigB)}}
	if err := hubClient.Update(ctx, updatedSecret); err != nil {
		t.Fatalf("failed to update secret: %v", err)
	}

	// Wait for re-engagement
	select {
	case <-aware.engaged:
	case <-ctx.Done():
		t.Fatal("timed out waiting for re-engagement after kubeconfig change")
	}

	// New cluster should have been created
	if len(factory.clusters) != 2 {
		t.Errorf("expected 2 clusters created (old + new), got %d", len(factory.clusters))
	}

	// Old cluster should have been stopped
	select {
	case <-oldCluster.stopped:
		// Expected — old cluster was cancelled
	case <-time.After(500 * time.Millisecond):
		t.Error("old cluster was not stopped after kubeconfig change")
	}
}

func TestProvider_ClusterProfileDeleted_RemovesCluster(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{"apiVersion": ClusterProfileAPIVersion, "kind": ClusterProfileKind, "metadata": map[string]interface{}{"name": "us", "namespace": "default"}, "spec": map[string]interface{}{"clusterManager": map[string]interface{}{"name": "us-fleet-manager"}}}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "us" + KubeconfigSecretSuffix, Namespace: "default"}, Data: map[string][]byte{"value": []byte(testKubeconfigA)}}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	factory := &fakeClusterFactory{}
	p := New(scheme, hubClient, 10*time.Millisecond)
	p.newCluster = factory.newCluster

	aware := &recordingAwareInternal{engaged: make(chan string, 5)}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() { _ = p.Run(ctx, &fakeManagerInternal{aware: aware}) }()

	// First engagement
	select {
	case <-aware.engaged:
	case <-ctx.Done():
		t.Fatal("timed out waiting for engagement")
	}

	if len(factory.clusters) != 1 {
		t.Fatalf("expected 1 cluster, got %d", len(factory.clusters))
	}
	oldCluster := factory.clusters[0]

	// Delete the ClusterProfile
	if err := hubClient.Delete(ctx, cp); err != nil {
		t.Fatalf("failed to delete ClusterProfile: %v", err)
	}

	// Wait for the next poll cycle to detect the deletion
	time.Sleep(200 * time.Millisecond)

	// Provider should have removed the cluster (context cancelled)
	select {
	case <-oldCluster.stopped:
		// Expected
	case <-time.After(500 * time.Millisecond):
		t.Error("cluster was not stopped after ClusterProfile deletion")
	}

	// Get should return ErrClusterNotFound
	_, err := p.Get(ctx, "us")
	if err == nil {
		t.Error("expected ErrClusterNotFound after deletion, got nil")
	}
}

func TestProvider_HashFunction_DetectsChange(t *testing.T) {
	hashA := hashKubeconfig(testKubeconfigA)
	hashB := hashKubeconfig(testKubeconfigB)

	if hashA == hashB {
		t.Fatal("expected different hashes for different kubeconfigs")
	}
}

// ── Existing tests (kept) ────────────────────────────────────────

func TestProvider_IndexField_ReplaysOnFutureEngagement(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{"apiVersion": ClusterProfileAPIVersion, "kind": ClusterProfileKind, "metadata": map[string]interface{}{"name": "us", "namespace": "default"}, "spec": map[string]interface{}{"clusterManager": map[string]interface{}{"name": "us-fleet-manager"}}}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "us" + KubeconfigSecretSuffix, Namespace: "default"}, Data: map[string][]byte{"value": []byte(testKubeconfigA)}}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	p := New(scheme, hubClient, 10*time.Millisecond)
	indexer := &fakeFieldIndexer{}
	p.newCluster = func(cfg *rest.Config, scheme *runtime.Scheme) (cluster.Cluster, error) {
		return &fakeCluster{indexer: indexer, started: make(chan struct{}), stopped: make(chan struct{})}, nil
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