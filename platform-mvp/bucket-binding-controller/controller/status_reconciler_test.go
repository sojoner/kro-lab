package controller

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"
)

func statusEnv(e *env) *StatusReconciler {
	return &StatusReconciler{Hub: e.hub, HubReader: e.r.HubReader, Clusters: e.r.Clusters, Config: testConfig}
}

func claimEvent(cluster string) mcreconcile.Request {
	return mcreconcile.Request{
		Request:     reconcile.Request{NamespacedName: client.ObjectKey{Namespace: tenantNS, Name: requestName}},
		ClusterName: cluster,
	}
}

func TestStatusReconciler_BoundClaimMakesRequestReady(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, []client.Object{claim(t, "Bound"), claimConfig()}, true)

	if _, err := statusEnv(e).Reconcile(context.Background(), claimEvent(testCluster)); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s := regionStatus(t, hubRequest(t, e.hub)); s["phase"] != "Ready" || s["endpoint"] != "http://rgw.svc:80" {
		t.Errorf("status = %v, want Ready with endpoint", s)
	}
}

func TestStatusReconciler_UnchangedStatusIsNotRewritten(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, []client.Object{claim(t, "Bound"), claimConfig()}, true)
	sr := statusEnv(e)

	if _, err := sr.Reconcile(context.Background(), claimEvent(testCluster)); err != nil {
		t.Fatal(err)
	}
	before := hubRequest(t, e.hub).GetResourceVersion()
	if _, err := sr.Reconcile(context.Background(), claimEvent(testCluster)); err != nil {
		t.Fatal(err)
	}
	if after := hubRequest(t, e.hub).GetResourceVersion(); after != before {
		t.Errorf("resourceVersion moved %s -> %s: an unchanged status must not be written", before, after)
	}
}

func TestStatusReconciler_IgnoresEventsItCannotMapToARequest(t *testing.T) {
	unlabelled := claim(t, "Bound")
	unlabelled.SetLabels(nil)
	// Labelled, but no hub request exists.
	e := newEnv([]client.Object{storageProfile()}, []client.Object{unlabelled}, true)
	sr := statusEnv(e)
	if _, err := sr.Reconcile(context.Background(), claimEvent(testCluster)); err != nil {
		t.Errorf("unlabelled claim must be ignored, got %v", err)
	}

	e = newEnv([]client.Object{storageProfile()}, []client.Object{claim(t, "Bound")}, true)
	if _, err := statusEnv(e).Reconcile(context.Background(), claimEvent(testCluster)); err != nil {
		t.Errorf("claim of a deleted request must be ignored, got %v", err)
	}

	if _, err := sr.Reconcile(context.Background(), mcreconcile.Request{
		Request:     reconcile.Request{NamespacedName: client.ObjectKey{Namespace: tenantNS, Name: "does-not-exist"}},
		ClusterName: testCluster,
	}); err != nil {
		t.Errorf("unknown claim must be ignored, got %v", err)
	}
}

func TestStatusReconciler_IgnoresClaimsOfAClusterThatDoesNotServeTheRegion(t *testing.T) {
	other := "us-storage"
	e := newEnv([]client.Object{requestObj(requestName), storageProfile(),
		clusterProfile(other, map[string]string{regionLabel: "us", offersLabel: "true"})},
		[]client.Object{claim(t, "Bound"), claimConfig()}, true)
	e.r.Clusters.(fakeClusters)[other] = &fakeSpoke{c: e.spoke}

	if _, err := statusEnv(e).Reconcile(context.Background(), claimEvent(other)); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	regions, found, _ := unstructured.NestedSlice(hubRequest(t, e.hub).Object, "status", "regions")
	if found && len(regions) > 0 {
		t.Errorf("a claim on the wrong region's cluster must not write status, got %v", regions)
	}
}

func TestStatusReconciler_UnknownClusterIsAnError(t *testing.T) {
	e := newEnv(nil, nil, false)
	if _, err := statusEnv(e).Reconcile(context.Background(), claimEvent(testCluster)); err == nil {
		t.Error("expected an error for a cluster the manager no longer knows")
	}
}
