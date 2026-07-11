package controller

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	clusterProfileAPIVersion = "multicluster.x-k8s.io/v1alpha1"
	clusterProfileKind       = "ClusterProfile"
	defaultKubeconfigSuffix  = "-access-kubeconfig"

	clusterConditionControlPlaneHealthy = "ControlPlaneHealthy"
)

var clusterProfileGVK = schema.GroupVersionKind{
	Group:   "multicluster.x-k8s.io",
	Version: "v1alpha1",
	Kind:    "ClusterProfile",
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
}

type TokenRotatorReconciler struct {
	hubClient client.Client

	dexIssuer             string
	dexClientID           string
	dexClientSecret       string
	dexClientIDTemplate   string
	newHTTPClient         func() *http.Client
	kubeconfigSecretSuffix string
}

type TokenRotatorOptions struct {
	DexIssuer              string
	DexClientID            string
	DexClientSecret        string
	DexClientIDTemplate    string
	KubeconfigSecretSuffix string
}

func SetupRotatorWithManager(mgr manager.Manager, opts TokenRotatorOptions) error {
	hubClient := mgr.GetClient()

	suffix := opts.KubeconfigSecretSuffix
	if suffix == "" {
		suffix = defaultKubeconfigSuffix
	}

	r := &TokenRotatorReconciler{
		hubClient:              hubClient,
		dexIssuer:              opts.DexIssuer,
		dexClientID:            opts.DexClientID,
		dexClientSecret:        opts.DexClientSecret,
		dexClientIDTemplate:    opts.DexClientIDTemplate,
		newHTTPClient:          func() *http.Client { return http.DefaultClient },
		kubeconfigSecretSuffix: suffix,
	}

	cp := &unstructured.Unstructured{}
	cp.SetGroupVersionKind(clusterProfileGVK)

	return ctrl.NewControllerManagedBy(mgr).
		Named("token-rotator").
		For(cp).
		WithOptions(controller.Options{MaxConcurrentReconciles: 1}).
		Complete(r)
}

func (r *TokenRotatorReconciler) dexClientIDForRegion(region string) string {
	if r.dexClientIDTemplate != "" {
		return strings.ReplaceAll(r.dexClientIDTemplate, "{region}", region)
	}
	return r.dexClientID
}

func (r *TokenRotatorReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	cp := &unstructured.Unstructured{}
	cp.SetGroupVersionKind(clusterProfileGVK)
	if err := r.hubClient.Get(ctx, req.NamespacedName, cp); err != nil {
		if apierrors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting ClusterProfile: %w", err)
	}

	if cp.GetDeletionTimestamp() != nil {
		return reconcile.Result{}, nil
	}

	if !isReady(cp) {
		logger.Info("ClusterProfile not healthy, skipping token rotation")
		return reconcile.Result{RequeueAfter: 30 * time.Second}, nil
	}

	region := cp.GetName()
	clientID := r.dexClientIDForRegion(region)

	token, err := r.fetchToken(clientID)
	if err != nil {
		RotationsTotal.WithLabelValues(region, "error").Inc()
		RotationErrorsTotal.WithLabelValues(region, "token_fetch").Inc()
		return reconcile.Result{}, fmt.Errorf("fetching Dex token for %s: %w", region, err)
	}

	server, caData := extractServerAndCA(cp)
	if server == "" {
		server, caData = extractServerAndCAFromSecret(ctx, r.hubClient, cp)
	}

	kubeconfig := buildKubeconfig(server, caData, token)

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      region + r.kubeconfigSecretSuffix,
			Namespace: req.Namespace,
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: clusterProfileAPIVersion,
				Kind:       clusterProfileKind,
				Name:       cp.GetName(),
				UID:        cp.GetUID(),
			}},
		},
		Data: map[string][]byte{"value": []byte(kubeconfig)},
	}

	existing := &corev1.Secret{}
	err = r.hubClient.Get(ctx, types.NamespacedName{
		Name:      secret.Name,
		Namespace: secret.Namespace,
	}, existing)
	if err == nil {
		existing.Data = secret.Data
		if updateErr := r.hubClient.Update(ctx, existing); updateErr != nil {
			RotationsTotal.WithLabelValues(region, "error").Inc()
			RotationErrorsTotal.WithLabelValues(region, "secret_update").Inc()
			return reconcile.Result{}, fmt.Errorf("updating kubeconfig Secret: %w", updateErr)
		}
		RotationsTotal.WithLabelValues(region, "success").Inc()
		LastRotationTimestamp.WithLabelValues(region).Set(float64(time.Now().Unix()))
		return reconcile.Result{RequeueAfter: 5 * time.Minute}, nil
	}

	if apierrors.IsNotFound(err) {
		if createErr := r.hubClient.Create(ctx, secret); createErr != nil {
			RotationsTotal.WithLabelValues(region, "error").Inc()
			RotationErrorsTotal.WithLabelValues(region, "secret_create").Inc()
			return reconcile.Result{}, fmt.Errorf("creating kubeconfig Secret: %w", createErr)
		}
		RotationsTotal.WithLabelValues(region, "success").Inc()
		LastRotationTimestamp.WithLabelValues(region).Set(float64(time.Now().Unix()))
		return reconcile.Result{RequeueAfter: 5 * time.Minute}, nil
	}

	return reconcile.Result{}, fmt.Errorf("checking Secret: %w", err)
}

func (r *TokenRotatorReconciler) fetchToken(clientID string) (string, error) {
	tokenURL := strings.TrimRight(r.dexIssuer, "/") + "/token"

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", clientID)
	form.Set("client_secret", r.dexClientSecret)
	form.Set("scope", "openid")

	httpReq, err := http.NewRequest("POST", tokenURL, bytes.NewReader([]byte(form.Encode())))
	if err != nil {
		return "", fmt.Errorf("building token request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := r.newHTTPClient().Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("Dex returned %d: %s", resp.StatusCode, string(body))
	}

	var tokenResp tokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", fmt.Errorf("decoding token response: %w", err)
	}

	if tokenResp.AccessToken == "" {
		return "", fmt.Errorf("empty access_token in Dex response")
	}

	return tokenResp.AccessToken, nil
}

func isReady(cp *unstructured.Unstructured) bool {
	conditions, found, _ := unstructured.NestedSlice(cp.Object, "status", "conditions")
	if !found {
		return false
	}

	for _, c := range conditions {
		cond, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if cond["type"] == clusterConditionControlPlaneHealthy {
			return cond["status"] == "True"
		}
	}
	return false
}

func extractServerAndCA(cp *unstructured.Unstructured) (string, []byte) {
	providers, found, _ := unstructured.NestedSlice(cp.Object, "status", "accessProviders")
	if !found {
		providers, found, _ = unstructured.NestedSlice(cp.Object, "status", "credentialProviders")
	}
	if !found {
		return "", nil
	}

	for _, p := range providers {
		provider, ok := p.(map[string]interface{})
		if !ok {
			continue
		}
		cluster, ok := provider["cluster"].(map[string]interface{})
		if !ok {
			continue
		}
		server, _, _ := unstructured.NestedString(cluster, "server")
		caStr, _, _ := unstructured.NestedString(cluster, "certificateAuthorityData")
		caData, _ := base64.StdEncoding.DecodeString(caStr)
		return server, caData
	}

	return "", nil
}

func extractServerAndCAFromSecret(ctx context.Context, cl client.Client, cp *unstructured.Unstructured) (string, []byte) {
	secretName := cp.GetName() + "-kubeconfig"
	secretNamespace := cp.GetNamespace()

	secret := &corev1.Secret{}
	if err := cl.Get(ctx, types.NamespacedName{
		Name: secretName, Namespace: secretNamespace,
	}, secret); err != nil {
		return "", nil
	}

	kubeconfigBytes, ok := secret.Data["value"]
	if !ok {
		return "", nil
	}

	server, ca, err := parseKubeconfigServer(kubeconfigBytes)
	if err != nil {
		return "", nil
	}
	return server, ca
}

func parseKubeconfigServer(data []byte) (string, []byte, error) {
	cfg, err := clientcmd.Load(data)
	if err != nil {
		return "", nil, err
	}
	for _, cluster := range cfg.Clusters {
		return cluster.Server, cluster.CertificateAuthorityData, nil
	}
	return "", nil, nil
}

func buildKubeconfig(server string, caData []byte, token string) string {
	clusterName := "spoke"
	userName := "dex-auth"

	config := clientcmdapi.Config{
		APIVersion: "v1",
		Kind:       "Config",
		Clusters: map[string]*clientcmdapi.Cluster{
			clusterName: {
				Server:                   server,
				CertificateAuthorityData: caData,
			},
		},
		Contexts: map[string]*clientcmdapi.Context{
			clusterName: {
				Cluster:  clusterName,
				AuthInfo: userName,
			},
		},
		CurrentContext: clusterName,
		AuthInfos: map[string]*clientcmdapi.AuthInfo{
			userName: {
				Token: token,
			},
		},
	}

	out, _ := clientcmd.Write(config)
	return string(out)
}