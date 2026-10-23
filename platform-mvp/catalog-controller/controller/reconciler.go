package controller

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	ctrl "sigs.k8s.io/controller-runtime"
)

var productGVK = schema.GroupVersionKind{
	Group:   "agora.platform.example.com",
	Version: "v1alpha1",
	Kind:    "Product",
}

type ProductReconciler struct {
	HubClient client.Client
	Writer    *ORDWriter
}

func SetupWithManager(mgr manager.Manager, r *ProductReconciler) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(productGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("product-controller").
		For(u).
		Complete(r)
}

func (r *ProductReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var products unstructured.UnstructuredList
	products.SetGroupVersionKind(productGVK)

	if err := r.HubClient.List(ctx, &products); err != nil {
		return reconcile.Result{}, fmt.Errorf("list products: %w", err)
	}

	doc := buildORDDocument(products.Items)
	r.Writer.SetORDDocument(doc)

	return reconcile.Result{}, nil
}

func buildORDDocument(items []unstructured.Unstructured) *ORDDocument {
	vendors := map[string]Vendor{}
	var ordProducts []ProductEntry
	var ordPackages []PackageEntry
	var ordAPIs []APIResourceEntry
	var ordBundles []ConsumptionBundle

	for _, item := range items {
		name := item.GetName()
		spec, ok := item.Object["spec"].(map[string]interface{})
		if !ok {
			continue
		}

		vendorName, _ := spec["vendor"].(string)
		displayName, _ := spec["displayName"].(string)
		if displayName == "" {
			displayName = name
		}
		description, _ := spec["description"].(string)
		visibility, _ := spec["visibility"].(string)
		licenseType, _ := spec["licenseType"].(string)
		supportInfo, _ := spec["supportInfo"].(string)

		labelsRaw, _ := spec["labels"].(map[string]interface{})
		ordLabels := map[string]string{}
		for k, v := range labelsRaw {
			if vs, ok := v.(string); ok {
				ordLabels[k] = vs
			}
		}

		if _, exists := vendors[vendorName]; !exists {
			vendors[vendorName] = Vendor{
				OrdID: fmt.Sprintf("%s:vendor:", vendorName),
				Title: vendorName,
			}
		}

		productOrdID := fmt.Sprintf("%s:product:%s:", vendorName, name)
		packageOrdID := fmt.Sprintf("%s:package:%s:v1alpha1:", vendorName, name)
		apiOrdID := fmt.Sprintf("%s:apiResource:%s:v1alpha1:", vendorName, name)
		bundleOrdID := fmt.Sprintf("%s:consumptionBundle:%s:default:", vendorName, name)

		ordProducts = append(ordProducts, ProductEntry{
			OrdID:            productOrdID,
			Title:            displayName,
			ShortDescription: description,
			Vendor:           vendorName,
			Labels:           ordLabels,
		})

		ordPackages = append(ordPackages, PackageEntry{
			OrdID:            packageOrdID,
			Title:            displayName,
			ShortDescription: description,
			Vendor:           vendorName,
			PartOfProducts:   []string{productOrdID},
			Version:          "1.0.0",
			Labels:           ordLabels,
			LicenseType:      licenseType,
			SupportInfo:      supportInfo,
		})

		ordAPIs = append(ordAPIs, APIResourceEntry{
			OrdID:            apiOrdID,
			Title:            displayName + " API",
			ShortDescription: description,
			APIProtocol:      "rest",
			PartOfPackage:    packageOrdID,
			Visibility:       visibility,
			ReleaseStatus:    "active",
			Labels:           ordLabels,
		})

		ordBundles = append(ordBundles, ConsumptionBundle{
			OrdID:   bundleOrdID,
			Title:   displayName + " Credentials",
			Visibility: visibility,
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