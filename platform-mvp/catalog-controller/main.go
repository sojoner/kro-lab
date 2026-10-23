package main

import (
	"context"
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/clientcmd"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	"github.com/sojoner/kro-lab/platform-mvp/catalog-controller/controller"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log

	kubeconfig := flag.String("kubeconfig", "", "Path to hub cluster kubeconfig")
	listenAddr := flag.String("listen", ":8080", "HTTP listen address")
	flag.Parse()

	scheme := runtime.NewScheme()

	hubConfig, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		log.Error(err, "failed to build hub config")
		os.Exit(1)
	}

	hubClient, err := client.New(hubConfig, client.Options{Scheme: scheme})
	if err != nil {
		log.Error(err, "failed to build hub client")
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	ordWriter := &controller.ORDWriter{}

	mgr, err := ctrl.NewManager(hubConfig, ctrl.Options{Scheme: scheme})
	if err != nil {
		log.Error(err, "failed to create manager")
		os.Exit(1)
	}

	reconciler := &controller.ProductReconciler{
		HubClient: hubClient,
		Writer:    ordWriter,
	}
	if err := controller.SetupWithManager(mgr, reconciler); err != nil {
		log.Error(err, "failed to setup controller")
		os.Exit(1)
	}

	go func() {
		log.Info("starting controller manager")
		if err := mgr.Start(ctx); err != nil {
			log.Error(err, "manager exited with error")
			os.Exit(1)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/open-resource-discovery", func(w http.ResponseWriter, r *http.Request) {
		doc, err := ordWriter.GetORDDocument()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(doc)
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	mux.HandleFunc("/v1/documents/default", func(w http.ResponseWriter, r *http.Request) {
		doc, err := ordWriter.GetORDDocument()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(doc)
	})

	server := &http.Server{Addr: *listenAddr, Handler: mux}

	go func() {
		log.Info("serving ORD document", "addr", *listenAddr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error(err, "http server exited")
		}
	}()

	<-ctx.Done()
	server.Shutdown(context.Background())
	log.Info("catalog-controller shut down")
}