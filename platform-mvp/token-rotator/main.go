package main

import (
	"context"
	"flag"
	"os"
	"os/signal"
	"syscall"

	"github.com/sojoner/kro-lab/platform-mvp/token-rotator/controller"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/clientcmd"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log

	hubKubeconfig := flag.String("hub-kubeconfig", "", "Path to hub cluster kubeconfig")
	metricsAddr := flag.String("metrics-bind-address", ":8080", "Address for metrics endpoint")
	dexIssuer := flag.String("dex-issuer", "https://dex.monitoring.svc:5556/dex", "Dex issuer URL")
	dexClientSecret := flag.String("dex-client-secret", "", "Dex client secret")
	kubeconfigSuffix := flag.String("kubeconfig-secret-suffix", "-access-kubeconfig", "Suffix for kubeconfig Secret names")
	flag.Parse()

	if *dexClientSecret == "" {
		*dexClientSecret = os.Getenv("DEX_CLIENT_SECRET")
	}
	if *dexClientSecret == "" {
		log.Error(nil, "dex-client-secret is required")
		os.Exit(1)
	}

	scheme := runtime.NewScheme()
	corev1.AddToScheme(scheme)

	hubConfig, err := clientcmd.BuildConfigFromFlags("", *hubKubeconfig)
	if err != nil {
		log.Error(err, "failed to build hub config")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(hubConfig, ctrl.Options{
		Scheme: scheme,
		Metrics: server.Options{
			BindAddress: *metricsAddr,
		},
	})
	if err != nil {
		log.Error(err, "failed to create manager")
		os.Exit(1)
	}

	if err := controller.SetupRotatorWithManager(mgr, controller.TokenRotatorOptions{
		DexIssuer:              *dexIssuer,
		DexClientSecret:        *dexClientSecret,
		DexClientIDTemplate:    "{region}-spoke-controller",
		KubeconfigSecretSuffix: *kubeconfigSuffix,
	}); err != nil {
		log.Error(err, "failed to setup token rotator")
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Info("starting token rotator")
	if err := mgr.Start(ctx); err != nil {
		log.Error(err, "manager exited with error")
		os.Exit(1)
	}
}