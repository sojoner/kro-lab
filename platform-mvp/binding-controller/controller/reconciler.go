package controller

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	ctrl "sigs.k8s.io/controller-runtime"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

var (
	RegionalBucketRequestGVK = schema.GroupVersionKind{
		Group:   "platform.example.com",
		Version: "v1alpha1",
		Kind:    "RegionalBucketRequest",
	}
	CephObjectStoreUserGVK = schema.GroupVersionKind{
		Group:   "ceph.rook.io",
		Version: "v1",
		Kind:    "CephObjectStoreUser",
	}
	ObjectBucketClaimGVK = schema.GroupVersionKind{
		Group:   "objectbucket.io",
		Version: "v1alpha1",
		Kind:    "ObjectBucketClaim",
	}
	rookNamespace  = "rook-ceph"
	objectStoreRef = "my-store"
)

// RegionalBucketReconciler watches RegionalBucketRequest on the hub only —
// no cross-cluster fan-out needed here — and creates the corresponding Rook
// objects on the target spoke, looked up via Manager.GetCluster.
type RegionalBucketReconciler struct {
	HubClient client.Client
	Manager   mcmanager.Manager
}

// SetupWithManager registers the reconciler against the hub's local
// manager. Using the builder (rather than bare controller.New, as before)
// also wires the Watch — a bare controller.New with no Watch never receives
// any events.
func SetupWithManager(mgr mcmanager.Manager, r *RegionalBucketReconciler) error {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(RegionalBucketRequestGVK)
	return ctrl.NewControllerManagedBy(mgr.GetLocalManager()).
		Named("regionalbucketrequest").
		For(obj).
		Complete(r)
}

func (r *RegionalBucketReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(RegionalBucketRequestGVK)
	err := r.HubClient.Get(ctx, req.NamespacedName, obj)
	if err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting regional bucket request: %w", err)
	}

	region, found, err := unstructured.NestedString(obj.Object, "spec", "region")
	if err != nil || !found {
		return reconcile.Result{}, fmt.Errorf("regional bucket request %s missing spec.region", req.Name)
	}

	spokeCluster, err := r.Manager.GetCluster(ctx, region)
	if err != nil {
		if err == multicluster.ErrClusterNotFound {
			logger.Info("region cluster not found", "region", region)
			return reconcile.Result{}, fmt.Errorf("unknown region %s: no cluster profile found", region)
		}
		return reconcile.Result{}, fmt.Errorf("getting spoke cluster for region %s: %w", region, err)
	}

	spokeClient := spokeCluster.GetClient()

	if err := r.ensureCephObjectStoreUser(ctx, spokeClient, obj); err != nil {
		return reconcile.Result{}, fmt.Errorf("ensuring CephObjectStoreUser: %w", err)
	}

	if err := r.ensureObjectBucketClaim(ctx, spokeClient, obj); err != nil {
		return reconcile.Result{}, fmt.Errorf("ensuring ObjectBucketClaim: %w", err)
	}

	return reconcile.Result{}, nil
}

func (r *RegionalBucketReconciler) ensureCephObjectStoreUser(ctx context.Context, spokeClient client.Client, obj *unstructured.Unstructured) error {
	name := obj.GetName()
	cosu := &unstructured.Unstructured{}
	cosu.SetGroupVersionKind(CephObjectStoreUserGVK)
	cosu.SetName(name)
	cosu.SetNamespace(rookNamespace)

	err := spokeClient.Get(ctx, client.ObjectKeyFromObject(cosu), cosu)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return fmt.Errorf("getting CephObjectStoreUser %s: %w", name, err)
	}

	cosu.Object["spec"] = map[string]interface{}{
		"store":       objectStoreRef,
		"displayName": name,
	}

	if err := spokeClient.Create(ctx, cosu); err != nil {
		return fmt.Errorf("creating CephObjectStoreUser %s: %w", name, err)
	}
	return nil
}

func (r *RegionalBucketReconciler) ensureObjectBucketClaim(ctx context.Context, spokeClient client.Client, obj *unstructured.Unstructured) error {
	name := obj.GetName()
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(ObjectBucketClaimGVK)
	obc.SetName(name)
	obc.SetNamespace(rookNamespace)

	err := spokeClient.Get(ctx, client.ObjectKeyFromObject(obc), obc)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return fmt.Errorf("getting ObjectBucketClaim %s: %w", name, err)
	}

	obc.Object["spec"] = map[string]interface{}{
		"bucketName":       name,
		"storageClassName": "rook-ceph-bucket",
		"additionalConfig": map[string]interface{}{},
	}

	if err := spokeClient.Create(ctx, obc); err != nil {
		return fmt.Errorf("creating ObjectBucketClaim %s: %w", name, err)
	}
	return nil
}
