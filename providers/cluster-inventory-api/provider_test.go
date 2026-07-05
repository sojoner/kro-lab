package clusterinventoryapi_test

import (
	"context"
	"testing"
	"time"

	provider "github.com/sojoner/kro-lab/providers/cluster-inventory-api"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/cluster"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

// Compile-time assertions that Provider satisfies the real
// sigs.k8s.io/multicluster-runtime Provider contract, not a hand-rolled
// look-alike.
var _ multicluster.Provider = (*provider.Provider)(nil)

const testPollInterval = 10 * time.Millisecond

// newClusterProfile builds a ClusterProfile matching the real upstream
// cluster-inventory-api schema: spec only allows clusterManager/displayName
// (verified against the installed CRD) — there is no kubeconfigSecretRef
// field, so the provider must locate the kubeconfig by naming convention
// instead (see provider.KubeconfigSecretSuffix).
func newClusterProfile(name, namespace string) *unstructured.Unstructured {
	return &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": provider.ClusterProfileAPIVersion,
			"kind":       provider.ClusterProfileKind,
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"clusterManager": map[string]interface{}{"name": name + "-fleet-manager"},
			},
		},
	}
}

// newKubeconfigSecret builds the kubeconfig Secret the provider expects to
// find at <clusterProfileName><provider.KubeconfigSecretSuffix> in the same
// namespace as the ClusterProfile.
func newKubeconfigSecret(clusterProfileName, namespace, kubeconfig string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      clusterProfileName + provider.KubeconfigSecretSuffix,
			Namespace: namespace,
		},
		Data: map[string][]byte{
			"value": []byte(kubeconfig),
		},
	}
}

const testKubeconfig = `apiVersion: v1
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
    token: test-token`

// recordingAware is a stub multicluster.Aware that records Engage calls,
// standing in for the real mcmanager.Manager in unit tests.
type recordingAware struct {
	engaged chan engagedCall
}

type engagedCall struct {
	name string
	cl   cluster.Cluster
}

func newRecordingAware() *recordingAware {
	return &recordingAware{engaged: make(chan engagedCall, 10)}
}

func (r *recordingAware) Engage(ctx context.Context, name string, cl cluster.Cluster) error {
	r.engaged <- engagedCall{name: name, cl: cl}
	return nil
}

// fakeManager satisfies mcmanager.Manager's Engage signature (Provider.Run's
// mgr parameter is typed mcmanager.Manager, not the narrower
// multicluster.Aware), delegating Engage to a recordingAware for assertions.
var _ mcmanager.Manager = (*fakeManager)(nil)

type fakeManager struct {
	mcmanager.Manager
	aware *recordingAware
}

func (f *fakeManager) Engage(ctx context.Context, name string, cl cluster.Cluster) error {
	return f.aware.Engage(ctx, name, cl)
}

func TestProviderGet_ClusterProfileNotFound(t *testing.T) {
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).Build()

	p := provider.New(scheme, hubClient, testPollInterval)
	_, err := p.Get(context.Background(), "nonexistent")
	if err != multicluster.ErrClusterNotFound {
		t.Errorf("expected ErrClusterNotFound, got %v", err)
	}
}

func TestProviderGet_ClusterProfileAPIGroup(t *testing.T) {
	// Must match the actual installed CRD group/version (cluster-inventory-api
	// upstream, applied via Makefile from
	// multicluster.x-k8s.io_clusterprofiles.yaml) — not a similarly-named but
	// wrong group, or the dynamic provider silently discovers zero clusters.
	gv := schema.GroupVersion{
		Group:   "multicluster.x-k8s.io",
		Version: "v1alpha1",
	}
	expected := gv.WithKind("ClusterProfile")
	if provider.ClusterProfileGVK != expected {
		t.Errorf("expected %v, got %v", expected, provider.ClusterProfileGVK)
	}
}

// TestProvider_Run_EngagesDiscoveredCluster proves the provider discovers
// ClusterProfile objects on the hub and engages the manager with a real
// cluster.Cluster for each one — the actual multicluster-runtime fan-out
// mechanism, not just an on-demand Get().
func TestProvider_Run_EngagesDiscoveredCluster(t *testing.T) {
	cp := newClusterProfile("us", "default")
	secret := newKubeconfigSecret("us", "default", testKubeconfig)

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, secret).Build()

	p := provider.New(scheme, hubClient, testPollInterval)
	aware := newRecordingAware()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = p.Run(ctx, &fakeManager{aware: aware}) }()

	select {
	case call := <-aware.engaged:
		if call.name != "us" {
			t.Errorf("expected cluster name %q, got %q", "us", call.name)
		}
		if call.cl == nil {
			t.Error("expected a non-nil cluster.Cluster")
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for provider to engage discovered cluster")
	}
}
