package main

import (
	"context"
	"flag"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/clientcmd"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	"github.com/sojoner/kro-lab/platform-mvp/deme-controller/controller"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log

	kubeconfig := flag.String("kubeconfig", "", "Path to kubeconfig")
	flag.Parse()

	scheme := runtime.NewScheme()

	cfg, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		log.Error(err, "failed to build config")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme})
	if err != nil {
		log.Error(err, "failed to create manager")
		os.Exit(1)
	}

	reconciler := &controller.DemeReconciler{
		Client: mgr.GetClient(),
	}
	if err := controller.SetupWithManager(mgr, reconciler); err != nil {
		log.Error(err, "failed to setup controller")
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Info("starting deme controller")
	if err := mgr.Start(ctx); err != nil {
		log.Error(err, "manager exited with error")
		os.Exit(1)
	}
}