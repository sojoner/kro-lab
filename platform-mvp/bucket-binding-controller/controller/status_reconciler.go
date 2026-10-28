package controller

import (
	"context"
	"fmt"

	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/adapter"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/config"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcbuilder "sigs.k8s.io/multicluster-runtime/pkg/builder"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"
)

// StatusReconciler is the cross-cluster half: it watches ObjectBucketClaim on
// every engaged spoke and reflects its state onto the owning hub request.
type StatusReconciler struct {
	Hub       client.Client
	HubReader client.Reader
	Clusters  ClusterGetter
	Config    config.Config
}

// SetupStatusReconcilerWithManager registers the watch on every cluster the
// manager's provider engages.
func SetupStatusReconcilerWithManager(mgr mcmanager.Manager, r *StatusReconciler) error {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(adapter.ObjectBucketClaimGVK)
	return mcbuilder.ControllerManagedBy(mgr).
		Named("regionalbucketrequest-status").
		For(obc).
		Complete(r)
}

func (r *StatusReconciler) Reconcile(ctx context.Context, req mcreconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	spoke, err := r.Clusters.GetCluster(ctx, req.ClusterName)
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("getting spoke cluster %s: %w", req.ClusterName, err)
	}

	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(adapter.ObjectBucketClaimGVK)
	if err := spoke.GetClient().Get(ctx, req.NamespacedName, obc); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	key, ok := adapter.RequestKey(obc.GetLabels())
	if !ok {
		return reconcile.Result{}, nil // not a platform claim
	}

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	if err := r.Hub.Get(ctx, key, obj); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	domainReq, err := adapter.RequestFromObject(obj, r.Config.DefaultNamespace)
	if err != nil {
		logger.Info("ignoring claim event for a malformed request", "request", key, "error", err.Error())
		return reconcile.Result{}, nil
	}
	name, ok, err := clusterNameFor(ctx, r.HubReader, r.Config, domainReq.Region)
	if err != nil {
		return reconcile.Result{}, err
	}
	if !ok || name != req.ClusterName {
		return reconcile.Result{}, nil // claim is not on the cluster serving the request's region
	}
	if err := syncStatus(ctx, r.Hub, spoke, obj, domainReq); err != nil && !apierrors.IsNotFound(err) {
		return reconcile.Result{}, err
	}
	return reconcile.Result{}, nil
}
