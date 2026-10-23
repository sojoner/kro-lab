package controller

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var (
	sealGVK = schema.GroupVersionKind{
		Group:   "agora.platform.example.com",
		Version: "v1alpha1",
		Kind:    "Seal",
	}
	bindingGVK = schema.GroupVersionKind{
		Group:   "agora.platform.example.com",
		Version: "v1alpha1",
		Kind:    "Binding",
	}
	offerGVK = schema.GroupVersionKind{
		Group:   "agora.platform.example.com",
		Version: "v1alpha1",
		Kind:    "Offer",
	}
)

type SealReconciler struct {
	Client client.Client
}

func SetupWithManager(mgr ctrl.Manager, r *SealReconciler) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(sealGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("seal-controller").
		For(u).
		Complete(r)
}

func (r *SealReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	seal := &unstructured.Unstructured{}
	seal.SetGroupVersionKind(sealGVK)
	if err := r.Client.Get(ctx, req.NamespacedName, seal); err != nil {
		if errors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting seal: %w", err)
	}

	phase, _, _ := unstructured.NestedString(seal.Object, "status", "phase")
	if phase == "" {
		phase = "Pending"
	}

	switch phase {
	case "Pending":
		return r.handlePending(ctx, seal)
	case "Revoked":
		return r.handleRevoked(ctx, seal)
	case "Sealed":
		expiresAt, found, _ := unstructured.NestedString(seal.Object, "status", "expiresAt")
		if found && expiresAt != "" {
			exp, err := time.Parse(time.RFC3339, expiresAt)
			if err == nil && time.Now().UTC().After(exp) {
				_ = unstructured.SetNestedField(seal.Object, "Expired", "status", "phase")
				r.setCondition(seal, "Sealed", "False", "Expired", "credential has expired")
				if err := r.Client.Status().Update(ctx, seal); err != nil {
					return reconcile.Result{}, err
				}
				return reconcile.Result{}, nil
			}
		}
		return reconcile.Result{}, nil
	default:
		return reconcile.Result{}, nil
	}
}

func (r *SealReconciler) handlePending(ctx context.Context, seal *unstructured.Unstructured) (reconcile.Result, error) {
	bindingRef, found, err := unstructured.NestedMap(seal.Object, "spec", "bindingRef")
	if err != nil || !found {
		r.setSealStatus(seal, "Pending", "MissingBindingRef", "spec.bindingRef is missing")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	bindingName, _, _ := unstructured.NestedString(bindingRef, "name")
	bindingNamespace, _, _ := unstructured.NestedString(bindingRef, "namespace")
	if bindingName == "" || bindingNamespace == "" {
		r.setSealStatus(seal, "Pending", "InvalidBindingRef", "bindingRef missing name or namespace")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	binding := &unstructured.Unstructured{}
	binding.SetGroupVersionKind(bindingGVK)
	if err := r.Client.Get(ctx, client.ObjectKey{Name: bindingName, Namespace: bindingNamespace}, binding); err != nil {
		r.setSealStatus(seal, "Pending", "BindingNotFound",
			fmt.Sprintf("binding %s/%s not found", bindingNamespace, bindingName))
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	offerRef, found, err := unstructured.NestedMap(binding.Object, "spec", "offerRef")
	if err != nil || !found {
		r.setSealStatus(seal, "Pending", "MissingOfferRef", "binding has no offerRef")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	offerName, _, _ := unstructured.NestedString(offerRef, "name")
	if offerName == "" {
		r.setSealStatus(seal, "Pending", "MissingOfferName", "binding offerRef missing name")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	offer := &unstructured.Unstructured{}
	offer.SetGroupVersionKind(offerGVK)
	if err := r.Client.Get(ctx, client.ObjectKey{Name: offerName}, offer); err != nil {
		r.setSealStatus(seal, "Pending", "OfferNotFound",
			fmt.Sprintf("offer %q not found", offerName))
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	template, _, _ := unstructured.NestedString(offer.Object, "spec", "credentialDelivery", "secretNameTemplate")
	if template == "" {
		template, _, _ = unstructured.NestedString(seal.Object, "spec", "secretNameTemplate")
	}
	if template == "" {
		template = fmt.Sprintf("seal-%s-creds", seal.GetName())
	}

	secretName := resolveSecretName(template, bindingName, bindingNamespace)
	password := generatePassword(32)

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: bindingNamespace,
		},
		Data: map[string][]byte{
			"password": []byte(password),
		},
	}

	if err := r.Client.Create(ctx, secret); err != nil {
		if !errors.IsAlreadyExists(err) {
			r.setSealStatus(seal, "Pending", "SecretCreateFailed",
				fmt.Sprintf("failed to create secret: %v", err))
			_ = r.Client.Status().Update(ctx, seal)
			return reconcile.Result{}, nil
		}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	_ = unstructured.SetNestedField(seal.Object, "Sealed", "status", "phase")
	_ = unstructured.SetNestedField(seal.Object, now, "status", "sealedAt")
	_ = unstructured.SetNestedField(seal.Object, map[string]interface{}{
		"name":      secretName,
		"namespace": bindingNamespace,
	}, "status", "credentialSecretRef")
	r.setSealStatus(seal, "Sealed", "Sealed", fmt.Sprintf("credential secret %s/%s created", bindingNamespace, secretName))
	_ = r.Client.Status().Update(ctx, seal)

	return reconcile.Result{}, nil
}

func (r *SealReconciler) handleRevoked(ctx context.Context, seal *unstructured.Unstructured) (reconcile.Result, error) {
	secretRef, found, err := unstructured.NestedMap(seal.Object, "status", "credentialSecretRef")
	if err != nil || !found {
		_ = unstructured.SetNestedField(seal.Object, "Revoked", "status", "phase")
		r.setCondition(seal, "Sealed", "False", "NoSecretRef", "no credential secret reference to delete")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	secretName, _, _ := unstructured.NestedString(secretRef, "name")
	secretNamespace, _, _ := unstructured.NestedString(secretRef, "namespace")
	if secretName == "" {
		_ = unstructured.SetNestedField(seal.Object, "Revoked", "status", "phase")
		r.setCondition(seal, "Sealed", "False", "NoSecretName", "credential secret ref missing name")
		_ = r.Client.Status().Update(ctx, seal)
		return reconcile.Result{}, nil
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: secretNamespace,
		},
	}

	if err := r.Client.Delete(ctx, secret); err != nil {
		if !errors.IsNotFound(err) {
			r.setSealStatus(seal, "Revoked", "SecretDeleteFailed",
				fmt.Sprintf("failed to delete secret: %v", err))
			_ = r.Client.Status().Update(ctx, seal)
			return reconcile.Result{}, nil
		}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	_ = unstructured.SetNestedField(seal.Object, "Revoked", "status", "phase")
	_ = unstructured.SetNestedField(seal.Object, now, "status", "revokedAt")
	r.setSealStatus(seal, "Revoked", "Revoked", fmt.Sprintf("credential secret %s/%s deleted", secretNamespace, secretName))
	_ = r.Client.Status().Update(ctx, seal)

	return reconcile.Result{}, nil
}

func (r *SealReconciler) setSealStatus(seal *unstructured.Unstructured, phase, reason, message string) {
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Sealed",
			"status":             conditionStatus(phase),
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	}
	_ = unstructured.SetNestedSlice(seal.Object, conditions, "status", "conditions")
}

func (r *SealReconciler) setCondition(seal *unstructured.Unstructured, condType, status, reason, message string) {
	conditions := []interface{}{
		map[string]interface{}{
			"type":               condType,
			"status":             status,
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	}
	_ = unstructured.SetNestedSlice(seal.Object, conditions, "status", "conditions")
}

func conditionStatus(phase string) string {
	if phase == "Sealed" {
		return "True"
	}
	return "False"
}

func resolveSecretName(template, bindingName, bindingNamespace string) string {
	name := template
	name = strings.ReplaceAll(name, "${binding.metadata.name}", bindingName)
	name = strings.ReplaceAll(name, "${binding.metadata.namespace}", bindingNamespace)
	return name
}

func generatePassword(length int) string {
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)[:length]
}