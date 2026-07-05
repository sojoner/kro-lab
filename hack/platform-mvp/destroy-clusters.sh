#!/usr/bin/env bash
set -euo pipefail

echo "Destroying clusters..."
kind delete cluster --name hub || true
kind delete cluster --name us || true
rm -f "$(dirname "${BASH_SOURCE[0]}")/kubeconfig-us-internal"
echo "Clusters destroyed."