#!/usr/bin/env bash
set -euo pipefail

US_CHART="${1:?usage: render-us-auth-config.sh <path-to-us-chart> [hub-ca-cert-file] [dex-ca-cert-file]}"
HUB_CA_FILE="${2:-}"
DEX_CA_FILE="${3:-}"

HELM_ARGS=(template us-auth "${US_CHART}" --show-only templates/auth-config.yaml)
if [ -n "${HUB_CA_FILE}" ]; then
  HELM_ARGS+=(--set-file "authConfiguration.hubIssuer.certificateAuthority=${HUB_CA_FILE}")
fi
if [ -n "${DEX_CA_FILE}" ]; then
  HELM_ARGS+=(--set-file "authConfiguration.dexIssuer.certificateAuthority=${DEX_CA_FILE}")
fi

helm "${HELM_ARGS[@]}" | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
sys.stdout.write(doc["data"]["authentication-configuration.yaml"])
'
