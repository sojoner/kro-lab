package controller

import (
	"context"
	"errors"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/adapter"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func reconcileRequest(e *env) (reconcile.Result, error) {
	return e.r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: client.ObjectKey{Namespace: hubNS, Name: requestName},
	})
}

func TestReconcile_CreatesClaimOnTheRegionsCluster(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, nil, true)

	res, err := reconcileRequest(e)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.RequeueAfter != testConfig.RequeueInterval {
		t.Errorf("RequeueAfter = %v, want %v", res.RequeueAfter, testConfig.RequeueInterval)
	}

	obc, err := specClaim(e.spoke)
	if err != nil {
		t.Fatalf("claim missing on the spoke: %v", err)
	}
	maxObjects, _, _ := unstructured.NestedString(obc.Object, "spec", "additionalConfig", "maxObjects")
	class, _, _ := unstructured.NestedString(obc.Object, "spec", "storageClassName")
	if maxObjects != "10000" || class != "ceph-bucket" {
		t.Errorf("claim spec: maxObjects=%q class=%q", maxObjects, class)
	}

	hub := hubRequest(t, e.hub)
	if !controllerutil.ContainsFinalizer(hub, Finalizer) {
		t.Error("finalizer not set on the hub request")
	}
	if s := regionStatus(t, hub); s["phase"] != "Pending" || s["bucketName"] != "acme-corp-media-eu" {
		t.Errorf("status = %v, want Pending with the bucket name", s)
	}
}

func TestReconcile_BoundClaimMakesRequestReadyWithEndpoint(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()},
		[]client.Object{claim(t, "Bound"), claimConfig()}, true)

	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	s := regionStatus(t, hubRequest(t, e.hub))
	if s["phase"] != "Ready" || s["endpoint"] != "http://rgw.svc:80" {
		t.Errorf("status = %v, want Ready with the RGW endpoint", s)
	}
}

func TestReconcile_BoundClaimWithoutConfigStaysPending(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()},
		[]client.Object{claim(t, "Bound")}, true)

	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s := regionStatus(t, hubRequest(t, e.hub)); s["phase"] != "Pending" {
		t.Errorf("phase = %v, want Pending until the endpoint is known", s["phase"])
	}
}

func TestReconcile_IsIdempotent(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, nil, true)
	for i := 0; i < 3; i++ {
		if _, err := reconcileRequest(e); err != nil {
			t.Fatalf("reconcile %d: %v", i, err)
		}
	}
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(claimListGVK)
	if err := e.spoke.List(context.Background(), list); err != nil || len(list.Items) != 1 {
		t.Errorf("claims = %d (err %v), want exactly 1", len(list.Items), err)
	}
}

func TestReconcile_LeavesAnExistingClaimUntouched(t *testing.T) {
	existing := claim(t, "Bound")
	_ = unstructured.SetNestedField(existing.Object, "5", "spec", "additionalConfig", "maxObjects")
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, []client.Object{existing, claimConfig()}, true)

	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	obc, _ := specClaim(e.spoke)
	if got, _, _ := unstructured.NestedString(obc.Object, "spec", "additionalConfig", "maxObjects"); got != "5" {
		t.Errorf("maxObjects = %q: a claim's quota is fixed once ordered", got)
	}
}

func TestReconcile_UnschedulableWhenNoClusterServesTheRegion(t *testing.T) {
	cases := map[string][]client.Object{
		"no profile at all": {requestObj(requestName)},
		"profile of another region": {requestObj(requestName),
			clusterProfile("us", map[string]string{regionLabel: "us", offersLabel: "true"})},
		// A same-region cluster that does not offer object storage must be ignored.
		"profile without the offers label": {requestObj(requestName),
			clusterProfile("eu", map[string]string{regionLabel: testRegion})},
	}
	for name, hubObjs := range cases {
		t.Run(name, func(t *testing.T) {
			e := newEnv(hubObjs, nil, true)
			res, err := reconcileRequest(e)
			if err != nil {
				t.Fatalf("an unschedulable request is a status, not an error: %v", err)
			}
			if res.RequeueAfter != testConfig.RequeueInterval {
				t.Errorf("RequeueAfter = %v, want %v", res.RequeueAfter, testConfig.RequeueInterval)
			}
			if s := regionStatus(t, hubRequest(t, e.hub)); s["phase"] != "Unschedulable" {
				t.Errorf("status = %v, want Unschedulable", s)
			}
			if _, err := specClaim(e.spoke); !apierrors.IsNotFound(err) {
				t.Errorf("no claim may be created, got err=%v", err)
			}
		})
	}
}

func TestReconcile_UnschedulableWhenTheClusterIsNotEngaged(t *testing.T) {
	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, nil, false)
	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s := regionStatus(t, hubRequest(t, e.hub)); s["phase"] != "Unschedulable" {
		t.Errorf("status = %v, want Unschedulable", s)
	}
}

func TestReconcile_InvalidSpecIsTerminal(t *testing.T) {
	bad := requestObj(requestName)
	delete(bad.Object["spec"].(map[string]interface{}), "maxSize")
	e := newEnv([]client.Object{bad, storageProfile()}, nil, true)

	_, err := reconcileRequest(e)
	if err == nil || !errors.Is(err, reconcile.TerminalError(nil)) {
		t.Errorf("expected a terminal error, got %v", err)
	}
}

func TestReconcile_UnknownRequestIsIgnored(t *testing.T) {
	e := newEnv(nil, nil, true)
	if _, err := reconcileRequest(e); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func deleting(t *testing.T, e *env) {
	t.Helper()
	if err := e.hub.Delete(context.Background(), hubRequest(t, e.hub)); err != nil {
		t.Fatalf("deleting request: %v", err)
	}
}

func requestWithFinalizer() *unstructured.Unstructured {
	req := requestObj(requestName)
	controllerutil.AddFinalizer(req, Finalizer)
	return req
}

func requestExists(e *env) bool {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	err := e.hub.Get(context.Background(), client.ObjectKey{Namespace: hubNS, Name: requestName}, u)
	return !apierrors.IsNotFound(err)
}

func TestReconcile_DeletionRemovesClaimThenReleasesFinalizer(t *testing.T) {
	e := newEnv([]client.Object{requestWithFinalizer(), storageProfile()}, []client.Object{claim(t, "Bound"), claimConfig()}, true)
	deleting(t, e)

	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := specClaim(e.spoke); !apierrors.IsNotFound(err) {
		t.Errorf("claim should be gone from the spoke, got err=%v", err)
	}
	if requestExists(e) {
		t.Error("request should be released once the claim is gone")
	}
}

func TestReconcile_DeletionWaitsWhileTheClaimIsStillGoing(t *testing.T) {
	// Rook's finalizer keeps the claim around while it deletes the bucket.
	slow := claim(t, "Bound")
	slow.SetFinalizers([]string{"objectbucket.io/finalizer"})
	e := newEnv([]client.Object{requestWithFinalizer(), storageProfile()}, []client.Object{slow}, true)
	deleting(t, e)

	res, err := reconcileRequest(e)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.RequeueAfter != testConfig.CleanupInterval {
		t.Errorf("RequeueAfter = %v, want %v", res.RequeueAfter, testConfig.CleanupInterval)
	}
	if !requestExists(e) {
		t.Fatal("the request must stay while the bucket still exists")
	}

	// Rook finishes: the claim disappears, the next pass releases the request.
	obc, _ := specClaim(e.spoke)
	obc.SetFinalizers(nil)
	if err := e.spoke.Update(context.Background(), obc); err != nil {
		t.Fatal(err)
	}
	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if requestExists(e) {
		t.Error("request should be released after the claim is gone")
	}
}

func TestReconcile_DeletionWithoutClusterReleasesImmediately(t *testing.T) {
	for name, engaged := range map[string]bool{"not engaged": false, "engaged": true} {
		t.Run(name, func(t *testing.T) {
			// No ClusterProfile for the region: nothing can hold a claim.
			e := newEnv([]client.Object{requestWithFinalizer()}, nil, engaged)
			deleting(t, e)
			if _, err := reconcileRequest(e); err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if requestExists(e) {
				t.Error("an unschedulable request must not block deletion")
			}
		})
	}
}

func TestReconcile_DeletionOfInvalidRequestStillReleases(t *testing.T) {
	req := requestWithFinalizer()
	delete(req.Object["spec"].(map[string]interface{}), "region")
	e := newEnv([]client.Object{req}, nil, true)
	deleting(t, e)

	if _, err := reconcileRequest(e); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if requestExists(e) {
		t.Error("a malformed request must not be stuck behind its finalizer")
	}
}

func TestReconcile_CountsResultsPerTenantAndRegion(t *testing.T) {
	ok := ReconcileTotal.WithLabelValues(tenantNS, testRegion, "success")
	failed := ReconcileTotal.WithLabelValues(tenantNS, testRegion, "error")
	okBefore, failedBefore := testutil.ToFloat64(ok), testutil.ToFloat64(failed)

	e := newEnv([]client.Object{requestObj(requestName), storageProfile()}, nil, true)
	if _, err := reconcileRequest(e); err != nil {
		t.Fatal(err)
	}
	if got := testutil.ToFloat64(ok) - okBefore; got != 1 {
		t.Errorf("success counter moved by %v, want 1", got)
	}

	// Cluster engaged but the hub cannot list profiles -> an error result.
	e.r.HubReader = failingReader{}
	if _, err := reconcileRequest(e); err == nil {
		t.Fatal("expected an error from the failing hub reader")
	}
	if got := testutil.ToFloat64(failed) - failedBefore; got != 1 {
		t.Errorf("error counter moved by %v, want 1", got)
	}
}

type failingReader struct{ client.Reader }

func (failingReader) List(context.Context, client.ObjectList, ...client.ListOption) error {
	return errors.New("hub unavailable")
}
