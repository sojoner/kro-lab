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
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func TestReconciler_CreatesSpokeResources(t *testing.T) {
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)

	hubClient := fake.NewClientBuilder().WithScheme(scheme).Build()
	spokeClient := fake.NewClientBuilder().WithScheme(scheme).Build()

	mgr := &fakeMCManager{
		spoke: map[string]cluster.Cluster{"us": &fakeSpokeCluster{c: spokeClient}},
		hub:   hubClient,
	}

	r := &RegionalBucketReconciler{
		HubClient: hubClient,
		Manager:   mgr,
	}

	obj := newRegionalBucketRequest("test-bucket-us", "us", 10, false)
	err := hubClient.Create(context.Background(), obj)
	if err != nil {
		t.Fatalf("failed to create test object: %v", err)
	}

	req := reconcile.Request{
		NamespacedName: client.ObjectKeyFromObject(obj),
	}
	_, err = r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected reconcile error: %v", err)
	}

	cosu := &unstructured.Unstructured{}
	cosu.SetGroupVersionKind(CephObjectStoreUserGVK)
	err = spokeClient.Get(context.Background(), client.ObjectKey{
		Name:      "test-bucket-us",
		Namespace: "rook-ceph",
	}, cosu)
	if err != nil {
		t.Fatalf("expected CephObjectStoreUser to exist: %v", err)
	}

	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(ObjectBucketClaimGVK)
	err = spokeClient.Get(context.Background(), client.ObjectKey{
		Name:      "test-bucket-us",
		Namespace: "rook-ceph",
	}, obc)
	if err != nil {
		t.Fatalf("expected ObjectBucketClaim to exist: %v", err)
	}
}

func TestReconciler_UnknownRegionReturnsError(t *testing.T) {
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)

	hubClient := fake.NewClientBuilder().WithScheme(scheme).Build()
	mgr := &fakeMCManager{
		spoke: map[string]cluster.Cluster{},
		hub:   hubClient,
	}

	r := &RegionalBucketReconciler{
		HubClient: hubClient,
		Manager:   mgr,
	}

	obj := newRegionalBucketRequest("test-bucket-unknown", "unknown", 10, false)
	err := hubClient.Create(context.Background(), obj)
	if err != nil {
		t.Fatalf("failed to create test object: %v", err)
	}

	req := reconcile.Request{
		NamespacedName: client.ObjectKeyFromObject(obj),
	}
	_, err = r.Reconcile(context.Background(), req)
	if err == nil {
		t.Error("expected error for unknown region")
	}
}

func newRegionalBucketRequest(name, region string, sizeGiB int, versioned bool) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(RegionalBucketRequestGVK)
	obj.SetName(name)
	obj.SetNamespace("default")
	obj.Object["spec"] = map[string]interface{}{
		"region":    region,
		"sizeGiB":   int64(sizeGiB),
		"versioned": versioned,
	}
	return obj
}
