package controller

import (
	"context"
	"fmt"
	"regexp"
	"time"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var citizenGVK = schema.GroupVersionKind{
	Group:   "agora.platform.example.com",
	Version: "v1alpha1",
	Kind:    "Citizen",
}

var oidcSubRe = regexp.MustCompile(`^\S+$`)

type CitizenReconciler struct {
	Client client.Client
}

func SetupWithManager(mgr ctrl.Manager, r *CitizenReconciler) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(citizenGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("citizen-controller").
		For(u).
		Complete(r)
}

func (r *CitizenReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	citizen := &unstructured.Unstructured{}
	citizen.SetGroupVersionKind(citizenGVK)
	if err := r.Client.Get(ctx, req.NamespacedName, citizen); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting citizen: %w", err)
	}

	phase, _, _ := unstructured.NestedString(citizen.Object, "status", "phase")
	if phase == "" {
		phase = "Pending"
	}

	switch phase {
	case "Pending":
		return r.handlePending(ctx, citizen)
	case "Active":
		return reconcile.Result{}, nil
	default:
		return reconcile.Result{}, nil
	}
}

func (r *CitizenReconciler) handlePending(ctx context.Context, citizen *unstructured.Unstructured) (reconcile.Result, error) {
	oidcSub, found, err := unstructured.NestedString(citizen.Object, "spec", "oidcSub")
	if err != nil || !found || oidcSub == "" {
		r.setCitizenStatus(citizen, "Pending", "MissingOIDCSub", "spec.oidcSub is missing")
		_ = r.Client.Status().Update(ctx, citizen)
		return reconcile.Result{}, nil
	}

	if !oidcSubRe.MatchString(oidcSub) {
		r.setCitizenStatus(citizen, "Pending", "InvalidOIDCSub", fmt.Sprintf("oidcSub %q contains spaces", oidcSub))
		_ = r.Client.Status().Update(ctx, citizen)
		return reconcile.Result{}, nil
	}

	r.setCitizenStatus(citizen, "Active", "Validated", "citizen validated and activated")
	_ = unstructured.SetNestedField(citizen.Object, "Active", "status", "phase")
	_ = r.Client.Status().Update(ctx, citizen)

	return reconcile.Result{}, nil
}

func (r *CitizenReconciler) setCitizenStatus(citizen *unstructured.Unstructured, phase, reason, message string) {
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             conditionStatus(phase),
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	}
	_ = unstructured.SetNestedSlice(citizen.Object, conditions, "status", "conditions")
}

func conditionStatus(phase string) string {
	if phase == "Active" {
		return "True"
	}
	return "False"
}