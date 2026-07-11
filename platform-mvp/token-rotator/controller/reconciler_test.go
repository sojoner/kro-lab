package controller

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func newClusterProfile(name, namespace string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "multicluster.x-k8s.io/v1alpha1",
		"kind":       "ClusterProfile",
		"metadata":   map[string]interface{}{"name": name, "namespace": namespace, "uid": "uid-" + name},
		"spec":       map[string]interface{}{"clusterManager": map[string]interface{}{"name": name + "-mgr"}},
	}}
}

func newHealthyClusterProfile(name, namespace string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "multicluster.x-k8s.io/v1alpha1",
		"kind":       "ClusterProfile",
		"metadata":   map[string]interface{}{"name": name, "namespace": namespace, "uid": "uid-" + name},
		"spec":       map[string]interface{}{"clusterManager": map[string]interface{}{"name": name + "-mgr"}},
		"status": map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{
					"type":   clusterConditionControlPlaneHealthy,
					"status": "True",
				},
			},
		},
	}}
}

func newKubeconfigSecret(name, namespace, kubeconfig string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
		Data:       map[string][]byte{"value": []byte(kubeconfig)},
	}
}

type stubDex struct {
	statusCode int
	body       string
	lastForm   string
}

func (s *stubDex) RoundTrip(req *http.Request) (*http.Response, error) {
	body, _ := io.ReadAll(req.Body)
	s.lastForm = string(body)
	return &http.Response{
		StatusCode: s.statusCode,
		Body:       io.NopCloser(strings.NewReader(s.body)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
	}, nil
}

func TestTokenRotator_CreatesKubeconfigSecret(t *testing.T) {
	cp := newHealthyClusterProfile("us", "default")
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp).Build()

	dex := &stubDex{
		statusCode: 200,
		body:       `{"access_token":"eyJhbG.rotated.sig","token_type":"bearer","expires_in":900}`,
	}

	r := &TokenRotatorReconciler{
		hubClient:      hubClient,
		dexIssuer:      "https://dex.example.com/dex",
		dexClientID:    "us-spoke-controller",
		dexClientSecret: "us-secret",
		newHTTPClient:  func() *http.Client { return &http.Client{Transport: dex} },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "us", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify Secret was created
	secret := &corev1.Secret{}
	err = hubClient.Get(context.Background(), types.NamespacedName{
		Name: "us-access-kubeconfig", Namespace: "default",
	}, secret)
	if err != nil {
		t.Fatalf("expected Secret us-access-kubeconfig: %v", err)
	}

	kubeconfig := string(secret.Data["value"])
	if !strings.Contains(kubeconfig, "eyJhbG.rotated.sig") {
		t.Errorf("expected kubeconfig to contain JWT token, got:\n%s", kubeconfig)
	}
	if !strings.Contains(kubeconfig, "kind: Config") {
		t.Errorf("expected valid kubeconfig YAML, got:\n%s", kubeconfig)
	}

	// Verify Dex was called correctly
	if !strings.Contains(dex.lastForm, "grant_type=client_credentials") {
		t.Errorf("expected client_credentials grant, got: %s", dex.lastForm)
	}
	if !strings.Contains(dex.lastForm, "client_id=us-spoke-controller") {
		t.Errorf("expected correct client ID, got: %s", dex.lastForm)
	}
}

func TestTokenRotator_UpdatesExistingSecretOnChange(t *testing.T) {
	cp := newHealthyClusterProfile("us", "default")
	existingSecret := newKubeconfigSecret("us-access-kubeconfig", "default", "old-kubeconfig")

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, existingSecret).Build()

	dex := &stubDex{
		statusCode: 200,
		body:       `{"access_token":"new.jwt.token","token_type":"bearer","expires_in":900}`,
	}

	r := &TokenRotatorReconciler{
		hubClient:      hubClient,
		dexIssuer:      "https://dex.example.com/dex",
		dexClientID:    "us-spoke-controller",
		dexClientSecret: "us-secret",
		newHTTPClient:  func() *http.Client { return &http.Client{Transport: dex} },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "us", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	secret := &corev1.Secret{}
	_ = hubClient.Get(context.Background(), types.NamespacedName{
		Name: "us-access-kubeconfig", Namespace: "default",
	}, secret)

	kubeconfig := string(secret.Data["value"])
	if !strings.Contains(kubeconfig, "new.jwt.token") {
		t.Errorf("expected updated kubeconfig with new token, got: %s", kubeconfig)
	}
}

func TestTokenRotator_DexUnavailableReturnsError(t *testing.T) {
	cp := newHealthyClusterProfile("us", "default")

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp).Build()

	dex := &stubDex{statusCode: 502, body: `{"error":"upstream timeout"}`}

	r := &TokenRotatorReconciler{
		hubClient:              hubClient,
		dexIssuer:              "https://dex.example.com/dex",
		dexClientID:            "us-spoke-controller",
		dexClientSecret:        "us-secret",
		newHTTPClient:          func() *http.Client { return &http.Client{Transport: dex} },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "us", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err == nil {
		t.Fatal("expected error when Dex is unavailable")
	}
	if !strings.Contains(err.Error(), "502") {
		t.Errorf("expected error to mention status code, got: %v", err)
	}
}

func TestTokenRotator_ClusterProfileDeletedNoOp(t *testing.T) {
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).Build()

	r := &TokenRotatorReconciler{
		hubClient:              hubClient,
		dexIssuer:              "https://dex.example.com/dex",
		dexClientID:            "us-spoke-controller",
		dexClientSecret:        "us-secret",
		newHTTPClient:          func() *http.Client { return http.DefaultClient },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "us", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("expected no error on deleted ClusterProfile: %v", err)
	}
}

func TestTokenRotator_ClusterProfileNotReadySkips(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "multicluster.x-k8s.io/v1alpha1",
		"kind":       "ClusterProfile",
		"metadata":   map[string]interface{}{"name": "us", "namespace": "default"},
		"spec":       map[string]interface{}{"clusterManager": map[string]interface{}{"name": "us-mgr"}},
		"status": map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{
					"type":   "ControlPlaneHealthy",
					"status": "False",
				},
			},
		},
	}}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp).Build()

	dex := &stubDex{statusCode: 200, body: `{"access_token":"x","expires_in":900}`}
	callCount := 0
	dexFn := func(req *http.Request) (*http.Response, error) {
		callCount++
		return dex.RoundTrip(req)
	}

	r := &TokenRotatorReconciler{
		hubClient:              hubClient,
		dexIssuer:              "https://dex.example.com/dex",
		dexClientID:            "us-spoke-controller",
		dexClientSecret:        "us-secret",
		newHTTPClient:          func() *http.Client { return &http.Client{Transport: roundTripperFunc(dexFn)} },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "us", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if callCount > 0 {
		t.Errorf("expected Dex NOT to be called for unhealthy ClusterProfile, got %d calls", callCount)
	}
}

func TestBuildKubeconfig(t *testing.T) {
	kubeconfig := buildKubeconfig("https://spoke.example.com:6443", []byte("ca-data"), "bearer-jwt-token")

	if !strings.Contains(kubeconfig, "https://spoke.example.com:6443") {
		t.Errorf("expected server URL, got: %s", kubeconfig)
	}
	if !strings.Contains(kubeconfig, "bearer-jwt-token") {
		t.Errorf("expected token, got: %s", kubeconfig)
	}
	if !strings.Contains(kubeconfig, "Y2EtZGF0YQ==") {
		t.Errorf("expected base64-encoded CA data, got: %s", kubeconfig)
	}
}

func TestExtractServerAndCA(t *testing.T) {
	cp := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "multicluster.x-k8s.io/v1alpha1",
		"kind":       "ClusterProfile",
		"metadata":   map[string]interface{}{"name": "us", "namespace": "default"},
		"status": map[string]interface{}{
			"accessProviders": []interface{}{
				map[string]interface{}{
					"name": "dex-oidc",
					"cluster": map[string]interface{}{
						"server":                   "https://spoke-api:6443",
						"certificateAuthorityData": "Y2EtZGF0YQ==",
					},
				},
			},
		},
	}}

	server, ca := extractServerAndCA(cp)
	if server != "https://spoke-api:6443" {
		t.Errorf("expected server URL, got: %s", server)
	}
	if string(ca) != "ca-data" {
		t.Errorf("expected CA data, got: %s", string(ca))
	}
}

func TestExtractServerAndCA_FallbackFromExistingSecret(t *testing.T) {
	cp := newClusterProfile("us", "default")
	existingSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "us-kubeconfig", Namespace: "default"},
		Data: map[string][]byte{"value": []byte(`apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://existing-server:6443
    certificate-authority-data: ZXhpc3RpbmctY2E=
  name: us
contexts:
- context:
    cluster: us
    user: admin
  name: kind-us
current-context: kind-us
users:
- name: admin
  user:
    token: old-token`)},
	}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp, existingSecret).Build()

	server, ca := extractServerAndCAFromSecret(context.Background(), hubClient, cp)
	if server != "https://existing-server:6443" {
		t.Errorf("expected fallback server, got: %s", server)
	}
	if string(ca) != "existing-ca" {
		t.Errorf("expected fallback CA, got: %s", string(ca))
	}
}

func TestParseKubeconfigServer(t *testing.T) {
	kc := `apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://test:6443
    certificate-authority-data: dGVzdC1jYQ==
  name: test`

	server, ca, err := parseKubeconfigServer([]byte(kc))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if server != "https://test:6443" {
		t.Errorf("expected server, got: %s", server)
	}
	if string(ca) != "test-ca" {
		t.Errorf("expected CA, got: %s", string(ca))
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestUnstructuredGVK(t *testing.T) {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(clusterProfileGVK)
	if obj.GroupVersionKind().Kind != "ClusterProfile" {
		t.Errorf("wrong kind: %s", obj.GroupVersionKind().Kind)
	}
}

// Helper used by tests that need to verify JSON output
func prettyJSON(v interface{}) string {
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}

func TestDexTokenResponseParsing(t *testing.T) {
	resp := strings.NewReader(`{"access_token":"abc.def.ghi","token_type":"bearer","expires_in":900,"scope":"openid"}`)
	var tr tokenResponse
	if err := json.NewDecoder(resp).Decode(&tr); err != nil {
		t.Fatalf("failed to decode: %v", err)
	}
	if tr.AccessToken != "abc.def.ghi" {
		t.Errorf("wrong token: %s", tr.AccessToken)
	}
	if tr.ExpiresIn != 900 {
		t.Errorf("wrong expiry: %d", tr.ExpiresIn)
	}
}

func TestSecretCreatedWithOwnerRef(t *testing.T) {
	cp := newHealthyClusterProfile("eu", "default")
	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)
	hubClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cp).Build()

	dex := &stubDex{
		statusCode: 200,
		body:       `{"access_token":"eu-token","token_type":"bearer","expires_in":900}`,
	}

	r := &TokenRotatorReconciler{
		hubClient:              hubClient,
		dexIssuer:              "https://dex.example.com/dex",
		dexClientID:            "eu-spoke-controller",
		dexClientSecret:        "eu-secret",
		newHTTPClient:          func() *http.Client { return &http.Client{Transport: dex} },
		kubeconfigSecretSuffix: "-access-kubeconfig",
	}

	req := reconcile.Request{NamespacedName: types.NamespacedName{Name: "eu", Namespace: "default"}}
	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	secret := &corev1.Secret{}
	err = hubClient.Get(context.Background(), types.NamespacedName{
		Name: "eu-access-kubeconfig", Namespace: "default",
	}, secret)
	if err != nil {
		t.Fatalf("expected Secret eu-access-kubeconfig: %v", err)
	}

	if len(secret.OwnerReferences) == 0 {
		t.Error("expected Secret to have an OwnerReference")
	}
}

func TestDexClientIDPerRegion(t *testing.T) {
	tests := []struct {
		region   string
		expected string
	}{
		{"us", "us-spoke-controller"},
		{"eu", "eu-spoke-controller"},
		{"asia", "asia-spoke-controller"},
	}

	r := &TokenRotatorReconciler{
		dexClientIDTemplate: "{region}-spoke-controller",
	}

	for _, tt := range tests {
		if got := r.dexClientIDForRegion(tt.region); got != tt.expected {
			t.Errorf("region %q: expected %q, got %q", tt.region, tt.expected, got)
		}
	}
}

func TestDexClientID_Fallback(t *testing.T) {
	r := &TokenRotatorReconciler{dexClientID: "fallback-client"}
	if got := r.dexClientIDForRegion("us"); got != "fallback-client" {
		t.Errorf("expected fallback, got %q", got)
	}
}