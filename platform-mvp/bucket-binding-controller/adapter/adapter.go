// Package adapter translates between Kubernetes objects and the domain model.
// All functions are pure: no clients, no I/O.
package adapter

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
)

var (
	RegionalBucketRequestGVK = schema.GroupVersionKind{Group: "platform.example.com", Version: "v1alpha1", Kind: "RegionalBucketRequest"}
	ObjectBucketClaimGVK     = schema.GroupVersionKind{Group: "objectbucket.io", Version: "v1alpha1", Kind: "ObjectBucketClaim"}
	ClusterProfileGVK        = schema.GroupVersionKind{Group: "multicluster.x-k8s.io", Version: "v1alpha1", Kind: "ClusterProfile"}
)

// Keys of the ConfigMap Rook writes next to a Bound claim.
const (
	ConfigHostKey = "BUCKET_HOST"
	ConfigPortKey = "BUCKET_PORT"
)

// RequestFromObject reads a RegionalBucketRequest into the domain model.
// fallbackNamespace is the spoke namespace used when the tenant label is absent.
func RequestFromObject(u *unstructured.Unstructured, fallbackNamespace string) (domain.Request, error) {
	missing := func(field string) error {
		return fmt.Errorf("regional bucket request %s: spec.%s is required", u.GetName(), field)
	}
	str := func(field string) (string, error) {
		v, found, err := unstructured.NestedString(u.Object, "spec", field)
		if err != nil || !found || v == "" {
			return "", missing(field)
		}
		return v, nil
	}
	num := func(field string) (int, error) {
		v, found, err := unstructured.NestedFieldNoCopy(u.Object, "spec", field)
		if err != nil || !found {
			return 0, missing(field)
		}
		switch n := v.(type) {
		case int64:
			return int(n), nil
		case float64:
			return int(n), nil
		}
		return 0, fmt.Errorf("regional bucket request %s: spec.%s must be an integer", u.GetName(), field)
	}

	r := domain.Request{
		Name:      u.GetName(),
		Namespace: u.GetNamespace(),
		Tenant:    domain.TenantNamespace(u.GetLabels(), fallbackNamespace),
		Bucket:    u.GetLabels()[domain.LabelBucket],
	}
	var err error
	if r.Region, err = str("region"); err != nil {
		return r, err
	}
	if r.MaxSize, err = str("maxSize"); err != nil {
		return r, err
	}
	if r.MaxObjects, err = num("maxObjects"); err != nil {
		return r, err
	}
	if err := domain.CheckBucketName(domain.BucketName(r)); err != nil {
		return r, fmt.Errorf("regional bucket request %s: %w", u.GetName(), err)
	}
	return r, nil
}

// OwnerLabels identify the claim that belongs to a request.
func OwnerLabels(r domain.Request) map[string]string {
	return map[string]string{
		domain.LabelRequest:          r.Name,
		domain.LabelRequestNamespace: r.Namespace,
	}
}

// RequestKey maps a spoke object back to its hub request via OwnerLabels.
func RequestKey(labels map[string]string) (types.NamespacedName, bool) {
	name, ns := labels[domain.LabelRequest], labels[domain.LabelRequestNamespace]
	if name == "" || ns == "" {
		return types.NamespacedName{}, false
	}
	return types.NamespacedName{Namespace: ns, Name: name}, true
}

// ObjectBucketClaim renders the request's claim in the tenant namespace. The
// claim carries the quota; Rook reads it from additionalConfig as strings.
func ObjectBucketClaim(r domain.Request, storageClass string) *unstructured.Unstructured {
	labels := make(map[string]interface{})
	for k, v := range OwnerLabels(r) {
		labels[k] = v
	}
	labels[domain.LabelTenant] = r.Tenant
	labels[domain.LabelBucket] = r.Bucket
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": ObjectBucketClaimGVK.GroupVersion().String(),
		"kind":       ObjectBucketClaimGVK.Kind,
		"metadata": map[string]interface{}{
			"name":      r.Name,
			"namespace": r.Tenant,
			"labels":    labels,
		},
		"spec": map[string]interface{}{
			"bucketName":       domain.BucketName(r),
			"storageClassName": storageClass,
			"additionalConfig": map[string]interface{}{
				"maxSize":    r.MaxSize,
				"maxObjects": strconv.Itoa(r.MaxObjects),
			},
		},
	}}
}

// ClaimOf reads the spoke's claim state. Either argument may be nil: a
// missing claim is the zero Claim, and a Bound claim whose ConfigMap is not
// written yet has no endpoint.
func ClaimOf(obc *unstructured.Unstructured, cm *corev1.ConfigMap) domain.Claim {
	var c domain.Claim
	if obc != nil {
		c.Phase, _, _ = unstructured.NestedString(obc.Object, "status", "phase")
	}
	if cm != nil {
		c.Host, c.Port = cm.Data[ConfigHostKey], cm.Data[ConfigPortKey]
	}
	return c
}

// ProfilesFromList reduces listed ClusterProfiles to what region resolution needs.
func ProfilesFromList(items []unstructured.Unstructured) []domain.Profile {
	profiles := make([]domain.Profile, 0, len(items))
	for _, item := range items {
		profiles = append(profiles, domain.Profile{Name: item.GetName(), Labels: item.GetLabels()})
	}
	return profiles
}

// StatusObject renders a region status as the request's status.regions value.
func StatusObject(s domain.Status) []interface{} {
	entry := map[string]interface{}{
		"region": s.Region,
		"phase":  string(s.Phase),
	}
	for k, v := range map[string]string{"bucketName": s.BucketName, "endpoint": s.Endpoint, "message": s.Message} {
		if v != "" {
			entry[k] = v
		}
	}
	return []interface{}{entry}
}

// StatusChanged reports whether writing s would alter the object's
// status.regions. Comparing the JSON form keeps int64/float64 decoding
// differences from looking like changes.
func StatusChanged(obj *unstructured.Unstructured, s domain.Status) bool {
	current, _, _ := unstructured.NestedFieldNoCopy(obj.Object, "status", "regions")
	a, _ := json.Marshal(current)
	b, _ := json.Marshal(StatusObject(s))
	return string(a) != string(b)
}

// SetStatus writes s into the object's status.regions, creating status when
// it is missing or null (as it is on a freshly created object).
func SetStatus(obj *unstructured.Unstructured, s domain.Status) error {
	if _, ok := obj.Object["status"].(map[string]interface{}); !ok {
		obj.Object["status"] = map[string]interface{}{}
	}
	return unstructured.SetNestedSlice(obj.Object, StatusObject(s), "status", "regions")
}
