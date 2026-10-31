package controller

import (
	"context"
	"testing"
	"time"

	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/adapter"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/config"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

const (
	hubNS       = "hub-ns"
	tenantNS    = "acme-corp"
	testRegion  = "eu"
	testCluster = "eu-storage" // serves testRegion; deliberately not named after it
	regionLabel = "platform.example.com/region"
	offersLabel = "platform.example.com/offers-object-storage"
	requestName = "media-eu"
)

var claimListGVK = schema.GroupVersionKind{Group: "objectbucket.io", Version: "v1alpha1", Kind: "ObjectBucketClaimList"}

var testConfig = config.Config{
	ClusterSelector: map[string]string{offersLabel: "true"},
	RegionLabel:     regionLabel,
	StorageClass:    "ceph-bucket",
	RequeueInterval: 30 * time.Second,
	CleanupInterval: 5 * time.Second,
}

type fakeSpoke struct {
	cluster.Cluster
	c client.Client
}

func (f *fakeSpoke) GetClient() client.Client    { return f.c }
func (f *fakeSpoke) GetAPIReader() client.Reader { return f.c }

type fakeClusters map[string]cluster.Cluster

func (f fakeClusters) GetCluster(_ context.Context, name string) (cluster.Cluster, error) {
	if cl, ok := f[name]; ok {
		return cl, nil
	}
	return nil, multicluster.ErrClusterNotFound
}

func requestObj(name string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{Object: map[string]interface{}{
		"metadata": map[string]interface{}{
			"name":      name,
			"namespace": hubNS,
			"labels":    map[string]interface{}{domain.LabelTenant: tenantNS, domain.LabelBucket: "media"},
		},
		"spec": map[string]interface{}{"region": testRegion, "maxSize": "1Gi", "maxObjects": int64(10000)},
	}}
	u.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	return u
}

func clusterProfile(name string, labels map[string]string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{Object: map[string]interface{}{
		"metadata": map[string]interface{}{"name": name, "namespace": "default"},
	}}
	u.SetGroupVersionKind(adapter.ClusterProfileGVK)
	u.SetLabels(labels)
	return u
}

// storageProfile is the hub's registration of the cluster that serves testRegion.
func storageProfile() *unstructured.Unstructured {
	return clusterProfile(testCluster, map[string]string{regionLabel: testRegion, offersLabel: "true"})
}

func newClient(objs ...client.Object) client.Client {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	return fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...).
		WithStatusSubresource(requestObj("x")).Build()
}

type env struct {
	hub, spoke client.Client
	r          *RequestReconciler
}

// newEnv wires a reconciler to fake hub/spoke clients. hubObjs should include
// the request and the ClusterProfiles; engaged=false leaves the storage
// cluster out of the manager's cluster set.
func newEnv(hubObjs []client.Object, spokeObjs []client.Object, engaged bool) *env {
	hub, spoke := newClient(hubObjs...), newClient(spokeObjs...)
	clusters := fakeClusters{}
	if engaged {
		clusters[testCluster] = &fakeSpoke{c: spoke}
	}
	return &env{hub: hub, spoke: spoke, r: &RequestReconciler{
		Hub: hub, HubReader: hub, Clusters: clusters, Config: testConfig,
	}}
}

func domainRequest(t *testing.T) domain.Request {
	t.Helper()
	r, err := adapter.RequestFromObject(requestObj(requestName))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// claim is the spoke's ObjectBucketClaim for the test request. phase "" leaves
// status unset, as on a claim Rook has not touched yet.
func claim(t *testing.T, phase string) *unstructured.Unstructured {
	t.Helper()
	obc := adapter.ObjectBucketClaim(domainRequest(t), testConfig.StorageClass)
	if phase != "" {
		_ = unstructured.SetNestedField(obc.Object, phase, "status", "phase")
	}
	return obc
}

func claimConfig() *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: requestName, Namespace: tenantNS},
		Data:       map[string]string{adapter.ConfigHostKey: "rgw.svc", adapter.ConfigPortKey: "80"},
	}
}

func specClaim(c client.Client) (*unstructured.Unstructured, error) {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(adapter.ObjectBucketClaimGVK)
	err := c.Get(context.Background(), client.ObjectKey{Namespace: tenantNS, Name: requestName}, obc)
	return obc, err
}

func hubRequest(t *testing.T, c client.Client) *unstructured.Unstructured {
	t.Helper()
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: hubNS, Name: requestName}, u); err != nil {
		t.Fatalf("getting request: %v", err)
	}
	return u
}

// regionStatus returns the single status.regions entry of a hub request.
func regionStatus(t *testing.T, u *unstructured.Unstructured) map[string]interface{} {
	t.Helper()
	regions, found, _ := unstructured.NestedSlice(u.Object, "status", "regions")
	if !found || len(regions) != 1 {
		t.Fatalf("expected one status.regions entry, got %v", regions)
	}
	return regions[0].(map[string]interface{})
}
