package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"
)

// fakeSpokeCluster adapts a fake client.Client to cluster.Cluster for tests
// (StatusReconciler only ever calls GetClient()).
type fakeSpokeCluster struct {
	cluster.Cluster
	c client.Client
}

func (f *fakeSpokeCluster) GetClient() client.Client { return f.c }

// fakeLocalManager adapts a fake client.Client to manager.Manager, standing
// in for mcmanager.Manager.GetLocalManager() in tests.
type fakeLocalManager struct {
	manager.Manager
	c client.Client
}

func (f *fakeLocalManager) GetClient() client.Client { return f.c }

// fakeMCManager is a minimal mcmanager.Manager test double: GetCluster
// returns a seeded spoke cluster by name, GetLocalManager exposes the hub.
type fakeMCManager struct {
	mcmanager.Manager
	spoke map[string]cluster.Cluster
	hub   client.Client
}

func (f *fakeMCManager) GetCluster(ctx context.Context, name string) (cluster.Cluster, error) {
	cl, ok := f.spoke[name]
	if !ok {
		return nil, multicluster.ErrClusterNotFound
	}
	return cl, nil
}

func (f *fakeMCManager) GetLocalManager() manager.Manager {
	return &fakeLocalManager{c: f.hub}
}

func newObjectBucketClaim(name, namespace, phase, objectBucketName string) *unstructured.Unstructured {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(ObjectBucketClaimGVK)
	obc.SetName(name)
	obc.SetNamespace(namespace)
	obc.Object["spec"] = map[string]interface{}{
		"objectBucketName": objectBucketName,
	}
	obc.Object["status"] = map[string]interface{}{
		"phase": phase,
	}
	return obc
}

func newObjectBucket(name, bucketHost string, bucketPort int64, bucketName string) *unstructured.Unstructured {
	ob := &unstructured.Unstructured{}
	ob.SetGroupVersionKind(ObjectBucketGVK)
	ob.SetName(name)
	ob.Object["spec"] = map[string]interface{}{
		"connection": map[string]interface{}{
			"endpoint": map[string]interface{}{
				"bucketHost": bucketHost,
				"bucketPort": bucketPort,
				"bucketName": bucketName,
			},
		},
	}
	return ob
}

func TestStatusReconciler_PropagatesFullConnectionInfo(t *testing.T) {
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)

	obc := newObjectBucketClaim("test-bucket-us", rookNamespace, "Bound", "obc-test-bucket-us")
	ob := newObjectBucket("obc-test-bucket-us", "rook-ceph-rgw-my-store.rook-ceph.svc", 80, "test-bucket-us")
	credsSecret := &corev1.Secret{}
	credsSecret.SetName("test-bucket-us")
	credsSecret.SetNamespace(rookNamespace)

	spokeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(obc, ob, credsSecret).Build()

	hubObj := newRegionalBucketRequest("test-bucket-us", "us", 10, false)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(hubObj).Build()

	mgr := &fakeMCManager{
		spoke: map[string]cluster.Cluster{"us": &fakeSpokeCluster{c: spokeClient}},
		hub:   hubClient,
	}

	r := &StatusReconciler{Manager: mgr}

	req := mcreconcile.Request{
		Request: reconcile.Request{
			NamespacedName: client.ObjectKey{Name: "test-bucket-us", Namespace: rookNamespace},
		},
		ClusterName: "us",
	}

	if _, err := r.Reconcile(context.Background(), req); err != nil {
		t.Fatalf("unexpected reconcile error: %v", err)
	}

	updated := &unstructured.Unstructured{}
	updated.SetGroupVersionKind(RegionalBucketRequestGVK)
	if err := hubClient.Get(context.Background(), client.ObjectKey{Name: "test-bucket-us", Namespace: hubObj.GetNamespace()}, updated); err != nil {
		t.Fatalf("failed to get updated RegionalBucketRequest: %v", err)
	}

	regions, found, err := unstructured.NestedSlice(updated.Object, "status", "regions")
	if err != nil || !found || len(regions) == 0 {
		t.Fatalf("expected status.regions to be populated, found=%v err=%v", found, err)
	}

	region, ok := regions[0].(map[string]interface{})
	if !ok {
		t.Fatalf("expected status.regions[0] to be a map, got %T", regions[0])
	}

	endpoint, _ := region["endpoint"].(string)
	bucketName, _ := region["bucketName"].(string)
	secretRef, _ := region["secretRef"].(map[string]interface{})

	if endpoint == "" {
		t.Error("expected non-empty endpoint")
	}
	if bucketName == "" {
		t.Error("expected non-empty bucketName")
	}
	if secretRef == nil {
		t.Fatal("expected non-nil secretRef")
	}
	if secretRef["name"] != "test-bucket-us" || secretRef["namespace"] != rookNamespace {
		t.Errorf("expected secretRef {name: test-bucket-us, namespace: %s}, got %v", rookNamespace, secretRef)
	}
}
