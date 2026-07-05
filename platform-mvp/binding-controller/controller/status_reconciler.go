package controller

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcbuilder "sigs.k8s.io/multicluster-runtime/pkg/builder"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"
)

var ObjectBucketGVK = schema.GroupVersionKind{
	Group:   "objectbucket.io",
	Version: "v1alpha1",
	Kind:    "ObjectBucket",
}

const (
	objectBucketClaimBoundPhase = "Bound"
	// hubNamespace is where GlobalBucket/RegionalBucketRequest instances
	// live on the hub — this MVP only ever applies them unnamespaced
	// (defaulting to "default"), matching the ObjectBucketClaim name
	// (but not namespace) used to look them up.
	hubNamespace = "default"
)

// StatusReconciler watches ObjectBucketClaim across engaged spoke clusters
// and propagates full connection info back to the matching
// RegionalBucketRequest on the hub. This is the cross-cluster fan-out half
// of the binding controller — RegionalBucketReconciler's hub-only watch
// creates the spoke resources, this reconciler watches spoke state and
// reports it back.
type StatusReconciler struct {
	Manager mcmanager.Manager
}

// SetupStatusReconcilerWithManager registers the status reconciler to watch
// ObjectBucketClaim on every cluster mgr's provider engages.
func SetupStatusReconcilerWithManager(mgr mcmanager.Manager, r *StatusReconciler) error {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(ObjectBucketClaimGVK)
	return mcbuilder.ControllerManagedBy(mgr).
		Named("regionalbucketrequest-status").
		For(obc).
		Complete(r)
}

func (r *StatusReconciler) Reconcile(ctx context.Context, req mcreconcile.Request) (reconcile.Result, error) {
	spokeCluster, err := r.Manager.GetCluster(ctx, req.ClusterName)
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("getting spoke cluster %s: %w", req.ClusterName, err)
	}
	spokeClient := spokeCluster.GetClient()

	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(ObjectBucketClaimGVK)
	if err := spokeClient.Get(ctx, req.NamespacedName, obc); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting ObjectBucketClaim: %w", err)
	}

	phase, _, _ := unstructured.NestedString(obc.Object, "status", "phase")
	if phase != objectBucketClaimBoundPhase {
		return reconcile.Result{}, nil
	}

	objectBucketName, found, _ := unstructured.NestedString(obc.Object, "spec", "objectBucketName")
	if !found || objectBucketName == "" {
		return reconcile.Result{}, nil
	}

	ob := &unstructured.Unstructured{}
	ob.SetGroupVersionKind(ObjectBucketGVK)
	if err := spokeClient.Get(ctx, types.NamespacedName{Name: objectBucketName}, ob); err != nil {
		return reconcile.Result{}, fmt.Errorf("getting ObjectBucket %s: %w", objectBucketName, err)
	}

	bucketHost, _, _ := unstructured.NestedString(ob.Object, "spec", "connection", "endpoint", "bucketHost")
	bucketPort, _, _ := unstructured.NestedInt64(ob.Object, "spec", "connection", "endpoint", "bucketPort")
	bucketName, _, _ := unstructured.NestedString(ob.Object, "spec", "connection", "endpoint", "bucketName")

	endpoint := bucketHost
	if bucketPort != 0 {
		endpoint = fmt.Sprintf("%s:%d", bucketHost, bucketPort)
	}

	// The credentials Secret is created by the bucket provisioner with the
	// same name and namespace as the ObjectBucketClaim. Only its existence
	// is referenced here — its contents are never read or logged.
	secretRef := map[string]interface{}{
		"name":      obc.GetName(),
		"namespace": obc.GetNamespace(),
	}

	hubClient := r.Manager.GetLocalManager().GetClient()
	latest := &unstructured.Unstructured{}
	latest.SetGroupVersionKind(RegionalBucketRequestGVK)
	hubKey := types.NamespacedName{Name: obc.GetName(), Namespace: hubNamespace}
	if err := hubClient.Get(ctx, hubKey, latest); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting RegionalBucketRequest on hub: %w", err)
	}

	regionStatus := []interface{}{map[string]interface{}{
		"region":     req.ClusterName,
		"phase":      phase,
		"endpoint":   endpoint,
		"bucketName": bucketName,
		"secretRef":  secretRef,
	}}
	if err := unstructured.SetNestedSlice(latest.Object, regionStatus, "status", "regions"); err != nil {
		return reconcile.Result{}, fmt.Errorf("setting status.regions: %w", err)
	}
	if err := hubClient.Update(ctx, latest); err != nil {
		return reconcile.Result{}, fmt.Errorf("updating status on hub: %w", err)
	}

	return reconcile.Result{}, nil
}
