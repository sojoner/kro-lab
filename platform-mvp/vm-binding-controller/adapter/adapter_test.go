package adapter

import (
	"reflect"
	"testing"

	"github.com/sojoner/kro-lab/platform-mvp/vm-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

func requestObject(mutate func(map[string]interface{})) *unstructured.Unstructured {
	spec := map[string]interface{}{
		"region":              "eu",
		"replicas":            int64(2),
		"cpu":                 int64(2),
		"memory":              "2Gi",
		"image":               "quay.io/kubevirt/cirros-container-disk-demo:v1.9.1",
		"cloudInitSecretName": "demo-cloudinit",
	}
	if mutate != nil {
		mutate(spec)
	}
	u := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "platform.example.com/v1alpha1",
		"kind":       "RegionalVmSetRequest",
		"metadata": map[string]interface{}{
			"name":      "demo-eu",
			"namespace": "hub-ns",
			"labels": map[string]interface{}{
				domain.LabelTenant: "acme-corp",
				domain.LabelVMSet:  "demo",
			},
		},
		"spec": spec,
	}}
	return u
}

func TestRequestFromObject(t *testing.T) {
	got, err := RequestFromObject(requestObject(nil), "default")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := domain.Request{
		Name: "demo-eu", Namespace: "hub-ns", Region: "eu", Tenant: "acme-corp", VMSet: "demo",
		Replicas: 2, CPU: 2, Memory: "2Gi",
		Image:           "quay.io/kubevirt/cirros-container-disk-demo:v1.9.1",
		CloudInitSecret: "demo-cloudinit",
	}
	if got != want {
		t.Errorf("RequestFromObject =\n%+v\nwant\n%+v", got, want)
	}
}

func TestRequestFromObject_FallsBackToDefaultNamespace(t *testing.T) {
	u := requestObject(nil)
	u.SetLabels(nil)
	got, err := RequestFromObject(u, "default")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Tenant != "default" {
		t.Errorf("Tenant = %q, want default", got.Tenant)
	}
}

func TestRequestFromObject_RejectsIncompleteSpec(t *testing.T) {
	for _, field := range []string{"region", "replicas", "cpu", "memory", "image", "cloudInitSecretName"} {
		t.Run("missing "+field, func(t *testing.T) {
			u := requestObject(func(spec map[string]interface{}) { delete(spec, field) })
			if _, err := RequestFromObject(u, "default"); err == nil {
				t.Errorf("expected an error when spec.%s is missing", field)
			}
		})
	}
}

func testRequest() domain.Request {
	return domain.Request{
		Name: "demo-eu", Namespace: "hub-ns", Region: "eu", Tenant: "acme-corp", VMSet: "demo",
		Replicas: 2, CPU: 2, Memory: "2Gi",
		Image:           "quay.io/kubevirt/cirros-container-disk-demo:v1.9.1",
		CloudInitSecret: "demo-cloudinit",
	}
}

func TestVirtualMachine(t *testing.T) {
	vm := VirtualMachine(testRequest(), "demo-eu-1", "Always")

	if vm.GetKind() != "VirtualMachine" || vm.GetAPIVersion() != "kubevirt.io/v1" {
		t.Errorf("unexpected type %s %s", vm.GetAPIVersion(), vm.GetKind())
	}
	if vm.GetName() != "demo-eu-1" || vm.GetNamespace() != "acme-corp" {
		t.Errorf("unexpected identity %s/%s", vm.GetNamespace(), vm.GetName())
	}
	wantLabels := map[string]string{
		domain.LabelTenant:           "acme-corp",
		domain.LabelVMSet:            "demo",
		domain.LabelRequest:          "demo-eu",
		domain.LabelRequestNamespace: "hub-ns",
	}
	if !reflect.DeepEqual(vm.GetLabels(), wantLabels) {
		t.Errorf("labels = %v, want %v", vm.GetLabels(), wantLabels)
	}

	check := func(path []string, want interface{}) {
		t.Helper()
		got, found, err := unstructured.NestedFieldNoCopy(vm.Object, path...)
		if err != nil || !found || !reflect.DeepEqual(got, want) {
			t.Errorf("%v = %v (found=%v err=%v), want %v", path, got, found, err, want)
		}
	}
	check([]string{"spec", "runStrategy"}, "Always")
	check([]string{"spec", "template", "spec", "domain", "cpu", "cores"}, int64(2))
	check([]string{"spec", "template", "spec", "domain", "memory", "guest"}, "2Gi")
	check([]string{"spec", "template", "spec", "domain", "devices", "logSerialConsole"}, true)

	volumes, _, _ := unstructured.NestedSlice(vm.Object, "spec", "template", "spec", "volumes")
	if len(volumes) != 2 {
		t.Fatalf("expected 2 volumes, got %d", len(volumes))
	}
	root := volumes[0].(map[string]interface{})
	if image, _, _ := unstructured.NestedString(root, "containerDisk", "image"); image != testRequest().Image {
		t.Errorf("root disk image = %q", image)
	}
	cloud := volumes[1].(map[string]interface{})
	if secret, _, _ := unstructured.NestedString(cloud, "cloudInitNoCloud", "secretRef", "name"); secret != "demo-cloudinit" {
		t.Errorf("cloud-init secret = %q", secret)
	}
}

func TestSpokeSecret(t *testing.T) {
	hub := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "demo-cloudinit", Namespace: "hub-ns", ResourceVersion: "42", UID: "x"},
		Data:       map[string][]byte{"userdata": []byte("#!/bin/sh\n")},
	}
	got := SpokeSecret(hub, testRequest())

	if got.Name != "demo-cloudinit" || got.Namespace != "acme-corp" {
		t.Errorf("identity = %s/%s", got.Namespace, got.Name)
	}
	if !reflect.DeepEqual(got.Data, hub.Data) {
		t.Errorf("data not copied: %v", got.Data)
	}
	if got.ResourceVersion != "" || got.UID != "" {
		t.Error("hub identity fields must not leak onto the spoke copy")
	}
	if got.Labels[domain.LabelTenant] != "acme-corp" || got.Labels[domain.LabelRequest] != "demo-eu" {
		t.Errorf("labels = %v", got.Labels)
	}
}

func TestOwnerLabels(t *testing.T) {
	want := map[string]string{domain.LabelRequest: "demo-eu", domain.LabelRequestNamespace: "hub-ns"}
	if got := OwnerLabels(testRequest()); !reflect.DeepEqual(got, want) {
		t.Errorf("OwnerLabels = %v, want %v", got, want)
	}
}

func TestRequestKey(t *testing.T) {
	key, ok := RequestKey(map[string]string{domain.LabelRequest: "demo-eu", domain.LabelRequestNamespace: "hub-ns"})
	if !ok || key != (types.NamespacedName{Namespace: "hub-ns", Name: "demo-eu"}) {
		t.Errorf("RequestKey = %v ok=%v", key, ok)
	}
	if _, ok := RequestKey(map[string]string{domain.LabelRequest: "demo-eu"}); ok {
		t.Error("a VM without the namespace label is not ours")
	}
	if _, ok := RequestKey(nil); ok {
		t.Error("an unlabelled VM is not ours")
	}
}

func TestStatusObject(t *testing.T) {
	got := StatusObject(domain.Status{Region: "eu", Phase: domain.PhaseReady, ReadyReplicas: 2})
	want := []interface{}{map[string]interface{}{"region": "eu", "phase": "Ready", "readyReplicas": int64(2)}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("StatusObject = %v, want %v", got, want)
	}

	withMsg := StatusObject(domain.UnschedulableStatus("us"))
	entry := withMsg[0].(map[string]interface{})
	if entry["message"] == "" || entry["phase"] != "Unschedulable" {
		t.Errorf("unschedulable entry = %v", entry)
	}
}

func vmWithReady(name string, ready *bool) unstructured.Unstructured {
	u := unstructured.Unstructured{Object: map[string]interface{}{"metadata": map[string]interface{}{"name": name}}}
	if ready != nil {
		u.Object["status"] = map[string]interface{}{"ready": *ready}
	}
	return u
}

func TestVMStates(t *testing.T) {
	yes, no := true, false
	all, ready := VMStates([]unstructured.Unstructured{
		vmWithReady("demo-eu-0", &yes),
		vmWithReady("demo-eu-1", &no),
		vmWithReady("demo-eu-2", nil),
	})
	if !reflect.DeepEqual(all, []string{"demo-eu-0", "demo-eu-1", "demo-eu-2"}) {
		t.Errorf("all = %v", all)
	}
	if !reflect.DeepEqual(ready, []string{"demo-eu-0"}) {
		t.Errorf("ready = %v", ready)
	}
}

func TestStatusChanged(t *testing.T) {
	s := domain.Status{Region: "eu", Phase: domain.PhaseReady, ReadyReplicas: 2}
	obj := &unstructured.Unstructured{Object: map[string]interface{}{}}
	if !StatusChanged(obj, s) {
		t.Error("an object with no status must count as changed")
	}
	// Decoded JSON numbers may arrive as float64; equal values must not look changed.
	obj.Object["status"] = map[string]interface{}{"regions": []interface{}{
		map[string]interface{}{"region": "eu", "phase": "Ready", "readyReplicas": float64(2)},
	}}
	if StatusChanged(obj, s) {
		t.Error("identical status must not count as changed")
	}
	if !StatusChanged(obj, domain.Status{Region: "eu", Phase: domain.PhasePending, ReadyReplicas: 1}) {
		t.Error("different status must count as changed")
	}
}

func TestSetStatus_ToleratesNilAndMissingStatus(t *testing.T) {
	s := domain.Status{Region: "eu", Phase: domain.PhasePending}
	for name, obj := range map[string]map[string]interface{}{
		"missing status": {},
		"nil status":     {"status": nil},
		"empty status":   {"status": map[string]interface{}{}},
	} {
		t.Run(name, func(t *testing.T) {
			u := &unstructured.Unstructured{Object: obj}
			if err := SetStatus(u, s); err != nil {
				t.Fatalf("SetStatus: %v", err)
			}
			if StatusChanged(u, s) {
				t.Error("status was not written")
			}
		})
	}
}
