package controller

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var demeGVK = schema.GroupVersionKind{
	Group:   "agora.platform.example.com",
	Version: "v1alpha1",
	Kind:    "Deme",
}

var offerGVK = schema.GroupVersionKind{
	Group:   "agora.platform.example.com",
	Version: "v1alpha1",
	Kind:    "Offer",
}

var bindingGVK = schema.GroupVersionKind{
	Group:   "agora.platform.example.com",
	Version: "v1alpha1",
	Kind:    "Binding",
}

type DemeReconciler struct {
	Client client.Client
}

func SetupWithManager(mgr ctrl.Manager, r *DemeReconciler) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(demeGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("deme-controller").
		For(u).
		Complete(r)
}

func (r *DemeReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	deme := &unstructured.Unstructured{}
	deme.SetGroupVersionKind(demeGVK)
	if err := r.Client.Get(ctx, req.NamespacedName, deme); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting deme: %w", err)
	}

	if !deme.GetDeletionTimestamp().IsZero() {
		return r.handleDelete(ctx, deme, logger)
	}

	phase, _, _ := unstructured.NestedString(deme.Object, "status", "phase")
	if phase == "" {
		phase = "Pending"
	}

	switch phase {
	case "Pending":
		return r.handlePending(ctx, deme, logger)
	case "Active":
		return reconcile.Result{}, nil
	case "Terminating":
		return r.handleTerminating(ctx, deme, logger)
	default:
		return reconcile.Result{}, nil
	}
}

func (r *DemeReconciler) handlePending(ctx context.Context, deme *unstructured.Unstructured, logger logr.Logger) (reconcile.Result, error) {
	nsName, found, err := unstructured.NestedString(deme.Object, "spec", "namespaceName")
	if err != nil || !found || nsName == "" {
		r.setDemeStatus(deme, "Pending", "MissingNamespace", "spec.namespaceName is missing")
		_ = r.Client.Status().Update(ctx, deme)
		return reconcile.Result{}, nil
	}

	_ = unstructured.SetNestedField(deme.Object, "Creating", "status", "phase")
	_ = unstructured.SetNestedField(deme.Object, nsName, "status", "namespaceName")
	_ = r.Client.Status().Update(ctx, deme)

	r.setDemeStatus(deme, "Creating", "CreatingNamespace", fmt.Sprintf("creating namespace %s", nsName))

	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: nsName}}
	if _, err := r.ensureNamespace(ctx, ns, deme); err != nil {
		r.setDemeStatus(deme, "Creating", "NamespaceCreationFailed", fmt.Sprintf("failed to create namespace: %v", err))
		_ = r.Client.Status().Update(ctx, deme)
		return reconcile.Result{}, err
	}

	count := r.countProductBindings(ctx, nsName)

	_ = unstructured.SetNestedField(deme.Object, "Active", "status", "phase")
	_ = unstructured.SetNestedField(deme.Object, nsName, "status", "namespaceName")
	_ = unstructured.SetNestedField(deme.Object, int64(count), "status", "productCount")

	r.setDemeStatus(deme, "Active", "NamespaceReady", fmt.Sprintf("namespace %s ready", nsName))
	_ = r.Client.Status().Update(ctx, deme)

	logger.Info("deme activated", "deme", deme.GetName(), "namespace", nsName)
	return reconcile.Result{}, nil
}

func (r *DemeReconciler) handleDelete(ctx context.Context, deme *unstructured.Unstructured, logger logr.Logger) (reconcile.Result, error) {
	phase, _, _ := unstructured.NestedString(deme.Object, "status", "phase")
	if phase == "Terminating" {
		return reconcile.Result{}, nil
	}

	_ = unstructured.SetNestedField(deme.Object, "Terminating", "status", "phase")
	r.setDemeStatus(deme, "Terminating", "DemeDeleted", "deme is being deleted; namespace preserved for admin cleanup")
	_ = r.Client.Status().Update(ctx, deme)

	logger.Info("deme terminating", "deme", deme.GetName())
	return reconcile.Result{}, nil
}

func (r *DemeReconciler) handleTerminating(ctx context.Context, deme *unstructured.Unstructured, logger logr.Logger) (reconcile.Result, error) {
	return reconcile.Result{}, nil
}

func (r *DemeReconciler) ensureNamespace(ctx context.Context, ns *corev1.Namespace, deme *unstructured.Unstructured) (*corev1.Namespace, error) {
	existing := &corev1.Namespace{}
	err := r.Client.Get(ctx, client.ObjectKey{Name: ns.Name}, existing)
	if err == nil {
		if existing.Labels == nil {
			existing.Labels = make(map[string]string)
		}
		demeLabels, _, _ := unstructured.NestedStringMap(deme.Object, "spec", "labels")
		for k, v := range demeLabels {
			existing.Labels[k] = v
		}
		if err := r.Client.Update(ctx, existing); err != nil {
			return existing, err
		}
		return existing, nil
	}
	if !errors.IsNotFound(err) {
		return nil, err
	}

	ns.Labels = make(map[string]string)
	ns.Labels["app.kubernetes.io/managed-by"] = "deme-controller"
	demeLabels, _, _ := unstructured.NestedStringMap(deme.Object, "spec", "labels")
	for k, v := range demeLabels {
		ns.Labels[k] = v
	}

	if err := r.Client.Create(ctx, ns); err != nil {
		return nil, err
	}
	return ns, nil
}

func (r *DemeReconciler) countProductBindings(ctx context.Context, nsName string) int {
	count := 0

	offerList := &unstructured.UnstructuredList{}
	offerList.SetGroupVersionKind(offerGVK)
	if err := r.Client.List(ctx, offerList); err == nil {
		for _, offer := range offerList.Items {
			allowTenants, _, _ := unstructured.NestedStringSlice(offer.Object, "spec", "allowTenants")
			if containsWildcard(allowTenants) || containsString(allowTenants, nsName) {
				count++
			}
		}
	}

	bindingList := &unstructured.UnstructuredList{}
	bindingList.SetGroupVersionKind(bindingGVK)
	if err := r.Client.List(ctx, bindingList); err == nil {
		for _, binding := range bindingList.Items {
			bindingNs := binding.GetNamespace()
			if bindingNs == nsName {
				count++
			}
		}
	}

	return count
}

func (r *DemeReconciler) setDemeStatus(deme *unstructured.Unstructured, phase, reason, message string) {
	status := phase == "Active" || phase == "Terminating"
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             conditionStatus(status),
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	}
	_ = unstructured.SetNestedSlice(deme.Object, conditions, "status", "conditions")
	_ = unstructured.SetNestedField(deme.Object, phase, "status", "phase")
}

func conditionStatus(active bool) string {
	if active {
		return "True"
	}
	return "False"
}

func containsWildcard(slice []string) bool {
	for _, s := range slice {
		if s == "*" {
			return true
		}
	}
	return false
}

func containsString(slice []string, target string) bool {
	for _, s := range slice {
		if s == target {
			return true
		}
	}
	return false
}