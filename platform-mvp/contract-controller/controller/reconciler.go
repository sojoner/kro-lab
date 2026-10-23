package controller

import (
	"context"
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	ctrl "sigs.k8s.io/controller-runtime"
)

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

type BindingReconciler struct {
	HubClient client.Client
	Writer    *ORDWriter
}

func SetupWithManager(mgr manager.Manager, r *BindingReconciler) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(bindingGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("binding-controller").
		For(u).
		Complete(r)
}

func (r *BindingReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var binding unstructured.Unstructured
	binding.SetGroupVersionKind(bindingGVK)

	if err := r.HubClient.Get(ctx, req.NamespacedName, &binding); err != nil {
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	offerRef, found, err := unstructured.NestedMap(binding.Object, "spec", "offerRef")
	if err != nil || !found {
		r.setBindingStatus(&binding, "Pending", "MissingOfferRef", "spec.offerRef is missing")
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, nil
	}

	offerName, _, _ := unstructured.NestedString(offerRef, "name")
	if offerName == "" {
		r.setBindingStatus(&binding, "Pending", "MissingOfferName", "spec.offerRef.name is missing")
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, nil
	}

	var offer unstructured.Unstructured
	offer.SetGroupVersionKind(offerGVK)
	if err := r.HubClient.Get(ctx, client.ObjectKey{Name: offerName}, &offer); err != nil {
		r.setBindingStatus(&binding, "Pending", "OfferNotFound",
			fmt.Sprintf("referenced offer %q not found", offerName))
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	bindingVersion, _, _ := unstructured.NestedString(binding.Object, "spec", "version")
	offerVersion, _, _ := unstructured.NestedString(offer.Object, "spec", "productRef", "version")

	if bindingVersion != "" && offerVersion != "" && bindingVersion != offerVersion {
		r.setBindingStatus(&binding, "Pending", "VersionMismatch",
			fmt.Sprintf("binding version %q does not match offer version %q", bindingVersion, offerVersion))
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, nil
	}

	bindingClaims, _, _ := unstructured.NestedSlice(binding.Object, "spec", "acceptedClaims")
	offerClaims, _, _ := unstructured.NestedSlice(offer.Object, "spec", "requestedClaims")

	if !validateClaimsSubset(bindingClaims, offerClaims) {
		r.setBindingStatus(&binding, "Pending", "ClaimMismatch",
			"binding acceptedClaims are not a valid subset of offer requestedClaims")
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, nil
	}

	allowTenants, _, _ := unstructured.NestedStringSlice(offer.Object, "spec", "allowTenants")
	if !tenantAllowed(binding.GetNamespace(), allowTenants) {
		r.setBindingStatus(&binding, "Pending", "TenantNotAllowed",
			fmt.Sprintf("namespace %q is not in offer allowTenants", binding.GetNamespace()))
		_ = r.HubClient.Status().Update(ctx, &binding)
		return reconcile.Result{}, nil
	}

	r.setBindingStatus(&binding, "Accepted", "OfferMatched",
		fmt.Sprintf("binding validated against offer %q", offerName))
	_ = r.HubClient.Status().Update(ctx, &binding)

	go r.rebuildORD(ctx)

	return reconcile.Result{}, nil
}

func (r *BindingReconciler) setBindingStatus(obj *unstructured.Unstructured, phase, reason, message string) {
	conditions := []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             conditionStatus(phase),
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": timestamp(),
		},
	}
	_ = unstructured.SetNestedSlice(obj.Object, conditions, "status", "conditions")
	_ = unstructured.SetNestedField(obj.Object, phase, "status", "phase")
}

func conditionStatus(phase string) string {
	if phase == "Accepted" || phase == "Active" {
		return "True"
	}
	return "False"
}

func validateClaimsSubset(bindingClaims, offerClaims []interface{}) bool {
	if len(bindingClaims) == 0 {
		return true
	}

	if len(offerClaims) == 0 {
		return false
	}

	offerClaimSet := make(map[string]bool)
	for _, oc := range offerClaims {
		ocMap, ok := oc.(map[string]interface{})
		if !ok {
			continue
		}
		group, _, _ := unstructured.NestedString(ocMap, "group")
		resource, _, _ := unstructured.NestedString(ocMap, "resource")
		offerClaimSet[group+"/"+resource] = true
	}

	for _, bc := range bindingClaims {
		bcMap, ok := bc.(map[string]interface{})
		if !ok {
			continue
		}
		group, _, _ := unstructured.NestedString(bcMap, "group")
		resource, _, _ := unstructured.NestedString(bcMap, "resource")
		if !offerClaimSet[group+"/"+resource] {
			return false
		}
	}
	return true
}

func tenantAllowed(namespace string, allowTenants []string) bool {
	if len(allowTenants) == 0 {
		return false
	}
	for _, t := range allowTenants {
		if t == "*" {
			return true
		}
		if strings.TrimSpace(t) == namespace {
			return true
		}
	}
	return false
}

func (r *BindingReconciler) rebuildORD(ctx context.Context) {
	var bindings unstructured.UnstructuredList
	bindings.SetGroupVersionKind(bindingGVK)
	if err := r.HubClient.List(ctx, &bindings); err != nil {
		return
	}

	var offers unstructured.UnstructuredList
	offers.SetGroupVersionKind(offerGVK)
	if err := r.HubClient.List(ctx, &offers); err != nil {
		return
	}

	doc := buildORDDocument(offers.Items, bindings.Items)
	r.Writer.SetORDDocument(doc)
}

func buildORDDocument(offers, bindings []unstructured.Unstructured) *ORDDocument {
	vendors := map[string]Vendor{}
	var ordProducts []ProductEntry
	var ordPackages []PackageEntry
	var ordAPIs []APIResourceEntry
	var ordBundles []ConsumptionBundle

	for _, offer := range offers {
		name := offer.GetName()
		vendor, _, _ := unstructured.NestedString(offer.Object, "spec", "vendor")
		version, _, _ := unstructured.NestedString(offer.Object, "spec", "productRef", "version")
		productName, _, _ := unstructured.NestedString(offer.Object, "spec", "productRef", "name")

		if _, exists := vendors[vendor]; !exists {
			vendors[vendor] = Vendor{
				OrdID: fmt.Sprintf("%s:vendor:", vendor),
				Title: vendor,
			}
		}

		productOrdID := fmt.Sprintf("%s:product:%s:", vendor, productName)
		packageOrdID := fmt.Sprintf("%s:package:%s:%s:", vendor, productName, version)
		apiOrdID := fmt.Sprintf("%s:apiResource:%s:%s:", vendor, productName, version)
		bundleOrdID := fmt.Sprintf("%s:consumptionBundle:%s:default:", vendor, name)

		ordProducts = append(ordProducts, ProductEntry{
			OrdID:  productOrdID,
			Title:  name,
			Vendor: vendor,
		})

		ordPackages = append(ordPackages, PackageEntry{
			OrdID:          packageOrdID,
			Title:          name,
			Vendor:         vendor,
			PartOfProducts: []string{productOrdID},
			Version:        version,
		})

		ordAPIs = append(ordAPIs, APIResourceEntry{
			OrdID:         apiOrdID,
			Title:         name + " Binding API",
			APIProtocol:   "rest",
			PartOfPackage: packageOrdID,
			Visibility:    "public",
			ReleaseStatus: "active",
		})

		ordBundles = append(ordBundles, ConsumptionBundle{
			OrdID:      bundleOrdID,
			Title:      name + " Binding",
			Visibility: "public",
		})
	}

	for _, binding := range bindings {
		bindingName := binding.GetName()
		vendor := binding.GetNamespace()

		vendorOrdID := fmt.Sprintf("%s:vendor:", vendor)
		if _, exists := vendors[vendor]; !exists {
			vendors[vendor] = Vendor{
				OrdID: vendorOrdID,
				Title: vendor,
			}
		}

		productOrdID := fmt.Sprintf("%s:product:%s:", vendor, bindingName)

		ordProducts = append(ordProducts, ProductEntry{
			OrdID:  productOrdID,
			Title:  bindingName,
			Vendor: vendor,
		})
	}

	vendorSlice := make([]Vendor, 0, len(vendors))
	for _, v := range vendors {
		vendorSlice = append(vendorSlice, v)
	}

	return &ORDDocument{
		OpenResourceDiscovery: ORDSpecVersion,
		Vendors:               vendorSlice,
		Products:              ordProducts,
		Packages:              ordPackages,
		APIResources:          ordAPIs,
		ConsumptionBundles:    ordBundles,
	}
}