package adapter

import (
	"reflect"
	"strings"
	"testing"

	"github.com/sojoner/kro-lab/platform-mvp/bucket-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func requestObject(spec map[string]interface{}, labels map[string]interface{}) *unstructured.Unstructured {
	meta := map[string]interface{}{"name": "media-eu", "namespace": "default"}
	if labels != nil {
		meta["labels"] = labels
	}
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "platform.example.com/v1alpha1",
		"kind":       "RegionalBucketRequest",
		"metadata":   meta,
		"spec":       spec,
	}}
}

func validSpec() map[string]interface{} {
	return map[string]interface{}{"region": "eu", "maxSize": "1Gi", "maxObjects": int64(10000)}
}

func tenantLabels() map[string]interface{} {
	return map[string]interface{}{domain.LabelTenant: "acme-corp", domain.LabelBucket: "media"}
}

func TestRequestFromObject(t *testing.T) {
	got, err := RequestFromObject(requestObject(validSpec(), tenantLabels()), "fallback")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := domain.Request{
		Name: "media-eu", Namespace: "default", Region: "eu", Tenant: "acme-corp",
		Bucket: "media", MaxSize: "1Gi", MaxObjects: 10000,
	}
	if got != want {
		t.Fatalf("request = %+v, want %+v", got, want)
	}
}

func TestRequestFromObject_TenantFallback(t *testing.T) {
	got, err := RequestFromObject(requestObject(validSpec(), nil), "fallback")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Tenant != "fallback" {
		t.Fatalf("tenant = %q, want fallback", got.Tenant)
	}
}

func TestRequestFromObject_AcceptsFloatObjects(t *testing.T) {
	spec := validSpec()
	spec["maxObjects"] = float64(10000)
	got, err := RequestFromObject(requestObject(spec, tenantLabels()), "fallback")
	if err != nil || got.MaxObjects != 10000 {
		t.Fatalf("got %+v, err %v", got, err)
	}
}

func TestRequestFromObject_Rejects(t *testing.T) {
	without := func(field string) map[string]interface{} {
		spec := validSpec()
		delete(spec, field)
		return spec
	}
	badObjects := validSpec()
	badObjects["maxObjects"] = "many"
	tooLong := requestObject(validSpec(), map[string]interface{}{domain.LabelTenant: strings.Repeat("t", 60)})

	cases := map[string]*unstructured.Unstructured{
		"missing region":       requestObject(without("region"), tenantLabels()),
		"missing maxSize":      requestObject(without("maxSize"), tenantLabels()),
		"missing maxObjects":   requestObject(without("maxObjects"), tenantLabels()),
		"non-integer limit":    requestObject(badObjects, tenantLabels()),
		"bucket name too long": tooLong,
	}
	for name, obj := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := RequestFromObject(obj, "fallback"); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}

func TestObjectBucketClaim(t *testing.T) {
	r := domain.Request{
		Name: "media-eu", Namespace: "default", Region: "eu", Tenant: "acme-corp",
		Bucket: "media", MaxSize: "1Gi", MaxObjects: 10000,
	}
	obc := ObjectBucketClaim(r, "ceph-bucket")

	if obc.GroupVersionKind() != ObjectBucketClaimGVK {
		t.Errorf("gvk = %v", obc.GroupVersionKind())
	}
	if obc.GetName() != "media-eu" || obc.GetNamespace() != "acme-corp" {
		t.Errorf("identity = %s/%s", obc.GetNamespace(), obc.GetName())
	}
	wantLabels := map[string]string{
		domain.LabelTenant: "acme-corp", domain.LabelBucket: "media",
		domain.LabelRequest: "media-eu", domain.LabelRequestNamespace: "default",
	}
	if !reflect.DeepEqual(obc.GetLabels(), wantLabels) {
		t.Errorf("labels = %v, want %v", obc.GetLabels(), wantLabels)
	}
	spec, _, _ := unstructured.NestedMap(obc.Object, "spec")
	want := map[string]interface{}{
		"bucketName":       "acme-corp-media-eu",
		"storageClassName": "ceph-bucket",
		// Rook reads the quota as strings.
		"additionalConfig": map[string]interface{}{"maxSize": "1Gi", "maxObjects": "10000"},
	}
	if !reflect.DeepEqual(spec, want) {
		t.Errorf("spec = %v, want %v", spec, want)
	}
}

func TestRequestKey(t *testing.T) {
	r := domain.Request{Name: "media-eu", Namespace: "default"}
	key, ok := RequestKey(OwnerLabels(r))
	if !ok || key.Name != "media-eu" || key.Namespace != "default" {
		t.Fatalf("key = %v, ok %v", key, ok)
	}
	if _, ok := RequestKey(map[string]string{domain.LabelRequest: "x"}); ok {
		t.Error("labels without the namespace must not map to a request")
	}
	if _, ok := RequestKey(nil); ok {
		t.Error("unlabelled objects must not map to a request")
	}
}

func claimObject(phase string) *unstructured.Unstructured {
	obc := &unstructured.Unstructured{Object: map[string]interface{}{"status": map[string]interface{}{}}}
	if phase != "" {
		_ = unstructured.SetNestedField(obc.Object, phase, "status", "phase")
	}
	return obc
}

func TestClaimOf(t *testing.T) {
	cm := &corev1.ConfigMap{Data: map[string]string{ConfigHostKey: "rgw.svc", ConfigPortKey: "80"}}
	cases := []struct {
		name string
		obc  *unstructured.Unstructured
		cm   *corev1.ConfigMap
		want domain.Claim
	}{
		{"bound with config", claimObject("Bound"), cm, domain.Claim{Phase: "Bound", Host: "rgw.svc", Port: "80"}},
		{"bound, config not written yet", claimObject("Bound"), nil, domain.Claim{Phase: "Bound"}},
		{"pending, no status phase", claimObject(""), nil, domain.Claim{}},
		{"missing claim", nil, nil, domain.Claim{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ClaimOf(c.obc, c.cm); got != c.want {
				t.Fatalf("ClaimOf = %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestProfilesFromList(t *testing.T) {
	cp := func(name string, labels map[string]interface{}) unstructured.Unstructured {
		return unstructured.Unstructured{Object: map[string]interface{}{
			"metadata": map[string]interface{}{"name": name, "labels": labels},
		}}
	}
	got := ProfilesFromList([]unstructured.Unstructured{
		cp("eu-storage", map[string]interface{}{"platform.example.com/region": "eu"}),
		cp("bare", nil),
	})
	want := []domain.Profile{
		{Name: "eu-storage", Labels: map[string]string{"platform.example.com/region": "eu"}},
		{Name: "bare"},
	}
	if len(got) != 2 || got[0].Name != want[0].Name || !reflect.DeepEqual(got[0].Labels, want[0].Labels) ||
		got[1].Name != "bare" || got[1].Labels["platform.example.com/region"] != "" {
		t.Fatalf("profiles = %+v, want %+v", got, want)
	}
}

func TestSetStatus_ThenNoChange(t *testing.T) {
	obj := requestObject(validSpec(), tenantLabels())
	s := domain.Status{Region: "eu", Phase: domain.PhaseReady, BucketName: "acme-corp-media-eu", Endpoint: "http://rgw.svc:80"}

	if !StatusChanged(obj, s) {
		t.Fatal("a fresh object must report a change")
	}
	if err := SetStatus(obj, s); err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	if StatusChanged(obj, s) {
		t.Fatal("writing the same status twice must not report a change")
	}
	regions, _, _ := unstructured.NestedSlice(obj.Object, "status", "regions")
	want := []interface{}{map[string]interface{}{
		"region": "eu", "phase": "Ready", "bucketName": "acme-corp-media-eu", "endpoint": "http://rgw.svc:80",
	}}
	if !reflect.DeepEqual(regions, want) {
		t.Fatalf("status.regions = %v, want %v", regions, want)
	}
}

func TestSetStatus_OmitsEmptyFieldsAndHandlesNullStatus(t *testing.T) {
	obj := requestObject(validSpec(), tenantLabels())
	obj.Object["status"] = nil // a freshly created object
	s := domain.UnschedulableStatus("asia")
	if err := SetStatus(obj, s); err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	regions, _, _ := unstructured.NestedSlice(obj.Object, "status", "regions")
	entry := regions[0].(map[string]interface{})
	if _, ok := entry["endpoint"]; ok {
		t.Error("empty endpoint must be omitted")
	}
	if entry["message"] == "" || entry["phase"] != "Unschedulable" {
		t.Errorf("entry = %v", entry)
	}
}
