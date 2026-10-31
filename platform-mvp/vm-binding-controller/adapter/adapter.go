// Package adapter translates between Kubernetes objects and the domain model.
// All functions are pure: no clients, no I/O.
package adapter

import (
	"encoding/json"
	"fmt"

	"github.com/sojoner/kro-lab/platform-mvp/vm-binding-controller/domain"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
)

var (
	RegionalVmSetRequestGVK = schema.GroupVersionKind{Group: "platform.example.com", Version: "v1alpha1", Kind: "RegionalVmSetRequest"}
	VirtualMachineGVK       = schema.GroupVersionKind{Group: "kubevirt.io", Version: "v1", Kind: "VirtualMachine"}
)

// RequestFromObject reads a RegionalVmSetRequest into the domain model.
// Tenant is empty when the tenant label is absent: there is no fallback.
func RequestFromObject(u *unstructured.Unstructured) (domain.Request, error) {
	str := func(field string) (string, error) {
		v, found, err := unstructured.NestedString(u.Object, "spec", field)
		if err != nil || !found || v == "" {
			return "", fmt.Errorf("regional vm set request %s: spec.%s is required", u.GetName(), field)
		}
		return v, nil
	}
	num := func(field string) (int, error) {
		v, found, err := unstructured.NestedFieldNoCopy(u.Object, "spec", field)
		if err != nil || !found {
			return 0, fmt.Errorf("regional vm set request %s: spec.%s is required", u.GetName(), field)
		}
		switch n := v.(type) {
		case int64:
			return int(n), nil
		case float64:
			return int(n), nil
		}
		return 0, fmt.Errorf("regional vm set request %s: spec.%s must be an integer", u.GetName(), field)
	}

	tenant, _ := domain.TenantNamespace(u.GetLabels()) // a missing tenant is the reconciler's call
	r := domain.Request{
		Name:      u.GetName(),
		Namespace: u.GetNamespace(),
		Tenant:    tenant,
		VMSet:     u.GetLabels()[domain.LabelVMSet],
	}
	var err error
	if r.Region, err = str("region"); err != nil {
		return r, err
	}
	if r.Memory, err = str("memory"); err != nil {
		return r, err
	}
	if r.Image, err = str("image"); err != nil {
		return r, err
	}
	if r.CloudInitSecret, err = str("cloudInitSecretName"); err != nil {
		return r, err
	}
	if r.Replicas, err = num("replicas"); err != nil {
		return r, err
	}
	if r.CPU, err = num("cpu"); err != nil {
		return r, err
	}
	return r, nil
}

// OwnerLabels identify the VMs and Secret that belong to a request.
func OwnerLabels(r domain.Request) map[string]string {
	return map[string]string{
		domain.LabelRequest:          r.Name,
		domain.LabelRequestNamespace: r.Namespace,
	}
}

func objectLabels(r domain.Request) map[string]string {
	labels := OwnerLabels(r)
	labels[domain.LabelTenant] = r.Tenant
	labels[domain.LabelVMSet] = r.VMSet
	return labels
}

// RequestKey maps a spoke object back to its hub request via OwnerLabels.
func RequestKey(labels map[string]string) (types.NamespacedName, bool) {
	name, ns := labels[domain.LabelRequest], labels[domain.LabelRequestNamespace]
	if name == "" || ns == "" {
		return types.NamespacedName{}, false
	}
	return types.NamespacedName{Namespace: ns, Name: name}, true
}

// VirtualMachine renders one VM of the request, booting the request's
// container disk with the cloud-init Secret attached as NoCloud user-data.
func VirtualMachine(r domain.Request, name, runStrategy string) *unstructured.Unstructured {
	labels := make(map[string]interface{})
	for k, v := range objectLabels(r) {
		labels[k] = v
	}
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": VirtualMachineGVK.GroupVersion().String(),
		"kind":       VirtualMachineGVK.Kind,
		"metadata": map[string]interface{}{
			"name":      name,
			"namespace": r.Tenant,
			"labels":    labels,
		},
		"spec": map[string]interface{}{
			"runStrategy": runStrategy,
			"template": map[string]interface{}{
				"spec": map[string]interface{}{
					"domain": map[string]interface{}{
						"cpu":    map[string]interface{}{"cores": int64(r.CPU)},
						"memory": map[string]interface{}{"guest": r.Memory},
						"devices": map[string]interface{}{
							// Serial output is how the platform proves cloud-init ran.
							"logSerialConsole": true,
							"disks": []interface{}{
								map[string]interface{}{"name": "root", "disk": map[string]interface{}{"bus": "virtio"}},
								map[string]interface{}{"name": "cloudinit", "disk": map[string]interface{}{"bus": "virtio"}},
							},
						},
					},
					"volumes": []interface{}{
						map[string]interface{}{"name": "root", "containerDisk": map[string]interface{}{"image": r.Image}},
						map[string]interface{}{"name": "cloudinit", "cloudInitNoCloud": map[string]interface{}{
							"secretRef": map[string]interface{}{"name": r.CloudInitSecret},
						}},
					},
				},
			},
		},
	}}
}

// SpokeSecret is the hub's cloud-init Secret re-homed into the tenant
// namespace on the spoke, dropping the hub's server-assigned identity.
func SpokeSecret(hub *corev1.Secret, r domain.Request) *corev1.Secret {
	data := make(map[string][]byte, len(hub.Data))
	for k, v := range hub.Data {
		data[k] = append([]byte(nil), v...)
	}
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      r.CloudInitSecret,
			Namespace: r.Tenant,
			Labels:    objectLabels(r),
		},
		Type: hub.Type,
		Data: data,
	}
}

// StatusObject renders a region status as the request's status.regions value.
func StatusObject(s domain.Status) []interface{} {
	entry := map[string]interface{}{
		"region":        s.Region,
		"phase":         string(s.Phase),
		"readyReplicas": int64(s.ReadyReplicas),
	}
	if s.Message != "" {
		entry["message"] = s.Message
	}
	return []interface{}{entry}
}

// VMStates splits listed VMs into every VM name and the subset reporting ready.
func VMStates(vms []unstructured.Unstructured) (all, ready []string) {
	for _, vm := range vms {
		all = append(all, vm.GetName())
		if ok, _, _ := unstructured.NestedBool(vm.Object, "status", "ready"); ok {
			ready = append(ready, vm.GetName())
		}
	}
	return all, ready
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
