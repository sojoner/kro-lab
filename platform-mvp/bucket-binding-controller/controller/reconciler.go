// Package controller is the impure shell: it reads and writes clusters and
// delegates every decision to the pure domain and adapter packages.
package controller

import (
	"context"
	"errors"
	"fmt"

	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/adapter"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/config"
	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

// Finalizer keeps a hub request alive until its claim and bucket are gone from the spoke.
const Finalizer = "platform.example.com/bucket-cleanup"

// unknownRegion labels metrics of requests whose spec cannot be read.
const unknownRegion = "unknown"

// ClusterGetter is the part of the multicluster manager the controllers use.
type ClusterGetter interface {
	GetCluster(ctx context.Context, name string) (cluster.Cluster, error)
}

// RequestReconciler turns each hub RegionalBucketRequest into an
// ObjectBucketClaim on the cluster serving the request's region. HubReader is
// uncached: it lists ClusterProfiles without starting an informer for them.
type RequestReconciler struct {
	Hub       client.Client
	HubReader client.Reader
	Clusters  ClusterGetter
	Config    config.Config
}

// SetupWithManager watches RegionalBucketRequest on the hub only; spoke
// engagement is handled by the provider.
func SetupWithManager(mgr mcmanager.Manager, r *RequestReconciler) error {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	return ctrl.NewControllerManagedBy(mgr.GetLocalManager()).
		Named("regionalbucketrequest").
		For(obj).
		Complete(r)
}

func (r *RequestReconciler) Reconcile(ctx context.Context, key reconcile.Request) (result reconcile.Result, retErr error) {
	logger := log.FromContext(ctx)

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(adapter.RegionalBucketRequestGVK)
	if err := r.Hub.Get(ctx, key.NamespacedName, obj); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	defer func() {
		outcome := "success"
		if retErr != nil {
			outcome = "error"
		}
		tenant, _ := domain.TenantNamespace(obj.GetLabels())
		ReconcileTotal.WithLabelValues(tenant, regionOf(obj), outcome).Inc()
	}()

	req, parseErr := adapter.RequestFromObject(obj)

	if !obj.GetDeletionTimestamp().IsZero() {
		return r.finalize(ctx, obj, req, parseErr)
	}
	if parseErr != nil {
		// Retrying cannot fix a malformed spec; the CRD schema should prevent it.
		return reconcile.Result{}, reconcile.TerminalError(parseErr)
	}

	if req.Tenant == "" {
		logger.Info("request has no tenant label", "label", domain.LabelTenant)
		return reconcile.Result{}, patchStatus(ctx, r.Hub, obj, domain.MissingTenantStatus(req.Region))
	}

	if !controllerutil.ContainsFinalizer(obj, Finalizer) {
		patch := client.MergeFrom(obj.DeepCopy())
		controllerutil.AddFinalizer(obj, Finalizer)
		if err := r.Hub.Patch(ctx, obj, patch); err != nil {
			return reconcile.Result{}, fmt.Errorf("adding finalizer: %w", err)
		}
	}

	spoke, found, err := r.spokeFor(ctx, req.Region)
	if err != nil {
		return reconcile.Result{}, err
	}
	if !found {
		logger.Info("no object-storage cluster for region", "region", req.Region)
		return reconcile.Result{RequeueAfter: r.Config.RequeueInterval},
			patchStatus(ctx, r.Hub, obj, domain.UnschedulableStatus(req.Region))
	}

	if err := r.syncClaim(ctx, spoke, req); err != nil {
		return reconcile.Result{}, err
	}
	if err := syncStatus(ctx, r.Hub, spoke, obj, req); err != nil {
		return reconcile.Result{}, err
	}
	// Periodic resync repairs claims deleted out-of-band.
	return reconcile.Result{RequeueAfter: r.Config.RequeueInterval}, nil
}

// spokeFor finds the engaged cluster serving region. found is false when no
// matching ClusterProfile exists or the manager has not engaged it (yet).
func (r *RequestReconciler) spokeFor(ctx context.Context, region string) (cluster.Cluster, bool, error) {
	name, ok, err := clusterNameFor(ctx, r.HubReader, r.Config, region)
	if err != nil || !ok {
		return nil, false, err
	}
	spoke, err := r.Clusters.GetCluster(ctx, name)
	if errors.Is(err, multicluster.ErrClusterNotFound) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("getting cluster %s for region %s: %w", name, region, err)
	}
	return spoke, true, nil
}

// clusterNameFor resolves region to a ClusterProfile that matches the
// controller's selector.
func clusterNameFor(ctx context.Context, hub client.Reader, cfg config.Config, region string) (string, bool, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(adapter.ClusterProfileGVK.GroupVersion().WithKind(adapter.ClusterProfileGVK.Kind + "List"))
	if err := hub.List(ctx, list, client.MatchingLabels(cfg.ClusterSelector)); err != nil {
		return "", false, fmt.Errorf("listing cluster profiles: %w", err)
	}
	name, ok := domain.ResolveCluster(region, cfg.RegionLabel, adapter.ProfilesFromList(list.Items))
	return name, ok, nil
}

// syncClaim creates the request's claim if it is missing. An existing claim is
// never changed: the quota is fixed once ordered.
func (r *RequestReconciler) syncClaim(ctx context.Context, spoke cluster.Cluster, req domain.Request) error {
	if _, err := getClaim(ctx, spoke.GetClient(), req); err == nil {
		return nil
	} else if !apierrors.IsNotFound(err) {
		return fmt.Errorf("reading claim %s: %w", req.Name, err)
	}
	err := spoke.GetClient().Create(ctx, adapter.ObjectBucketClaim(req, r.Config.StorageClass))
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return fmt.Errorf("creating claim %s: %w", req.Name, err)
	}
	return nil
}

// finalize removes the request's claim from the spoke, waits until Rook has
// deleted the bucket, then releases the finalizer. Requests that cannot be
// placed or parsed are released at once.
func (r *RequestReconciler) finalize(ctx context.Context, obj *unstructured.Unstructured, req domain.Request, parseErr error) (reconcile.Result, error) {
	if !controllerutil.ContainsFinalizer(obj, Finalizer) {
		return reconcile.Result{}, nil
	}
	if parseErr == nil && req.Tenant != "" {
		spoke, found, err := r.spokeFor(ctx, req.Region)
		if err != nil {
			return reconcile.Result{}, err
		}
		if found {
			gone, err := deleteClaim(ctx, spoke, req)
			if err != nil {
				return reconcile.Result{}, err
			}
			if !gone {
				return reconcile.Result{RequeueAfter: r.Config.CleanupInterval}, nil
			}
		}
	}
	patch := client.MergeFrom(obj.DeepCopy())
	controllerutil.RemoveFinalizer(obj, Finalizer)
	return reconcile.Result{}, client.IgnoreNotFound(r.Hub.Patch(ctx, obj, patch))
}

// deleteClaim asks for the claim's deletion and reports whether it is gone.
func deleteClaim(ctx context.Context, spoke cluster.Cluster, req domain.Request) (bool, error) {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(adapter.ObjectBucketClaimGVK)
	obc.SetName(req.Name)
	obc.SetNamespace(req.Tenant)
	if err := spoke.GetClient().Delete(ctx, obc); client.IgnoreNotFound(err) != nil {
		return false, fmt.Errorf("deleting claim %s: %w", req.Name, err)
	}
	_, err := getClaim(ctx, spoke.GetAPIReader(), req)
	switch {
	case apierrors.IsNotFound(err):
		return true, nil
	case err != nil:
		return false, fmt.Errorf("reading claim %s: %w", req.Name, err)
	}
	return false, nil
}

func getClaim(ctx context.Context, c client.Reader, req domain.Request) (*unstructured.Unstructured, error) {
	obc := &unstructured.Unstructured{}
	obc.SetGroupVersionKind(adapter.ObjectBucketClaimGVK)
	err := c.Get(ctx, types.NamespacedName{Namespace: req.Tenant, Name: req.Name}, obc)
	return obc, err
}

// syncStatus recomputes the request's region status from the spoke's claim and
// writes it to the hub only when it changed.
func syncStatus(ctx context.Context, hub client.Client, spoke cluster.Cluster, obj *unstructured.Unstructured, req domain.Request) error {
	var obc *unstructured.Unstructured
	var cm *corev1.ConfigMap
	found, err := getClaim(ctx, spoke.GetClient(), req)
	switch {
	case err == nil:
		obc = found
	case !apierrors.IsNotFound(err):
		return fmt.Errorf("reading claim %s: %w", req.Name, err)
	}
	// Rook writes the endpoint into a ConfigMap named after the claim once Bound.
	if obc != nil && adapter.ClaimOf(obc, nil).Phase == domain.ClaimBound {
		cm = &corev1.ConfigMap{}
		err := spoke.GetAPIReader().Get(ctx, types.NamespacedName{Namespace: req.Tenant, Name: req.Name}, cm)
		switch {
		case apierrors.IsNotFound(err):
			cm = nil
		case err != nil:
			return fmt.Errorf("reading claim config %s: %w", req.Name, err)
		}
	}
	return patchStatus(ctx, hub, obj, domain.ReadyStatus(req, adapter.ClaimOf(obc, cm)))
}

func patchStatus(ctx context.Context, hub client.Client, obj *unstructured.Unstructured, s domain.Status) error {
	if !adapter.StatusChanged(obj, s) {
		return nil
	}
	patch := client.MergeFrom(obj.DeepCopy())
	if err := adapter.SetStatus(obj, s); err != nil {
		return fmt.Errorf("setting status.regions: %w", err)
	}
	if err := hub.Status().Patch(ctx, obj, patch); err != nil {
		return fmt.Errorf("patching request status: %w", err)
	}
	return nil
}

func regionOf(obj *unstructured.Unstructured) string {
	if region, _, _ := unstructured.NestedString(obj.Object, "spec", "region"); region != "" {
		return region
	}
	return unknownRegion
}
