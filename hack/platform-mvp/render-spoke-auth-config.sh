#!/usr/bin/env bash
set -euo pipefail

SPOKE_CHART="${1:?usage: render-spoke-auth-config.sh <path-to-spoke-chart> <spoke-values-file> [hub-ca-cert-file] [dex-ca-cert-file] [dex-issuer-url]}"
SPOKE_VALUES="${2:?usage: render-spoke-auth-config.sh <path-to-spoke-chart> <spoke-values-file> [hub-ca-cert-file] [dex-ca-cert-file] [dex-issuer-url]}"
HUB_CA_FILE="${3:-}"
DEX_CA_FILE="${4:-}"
DEX_ISSUER_URL="${5:-}"

HELM_ARGS=(template spoke-auth "${SPOKE_CHART}" -f "${SPOKE_VALUES}" --show-only templates/auth-config.yaml)
if [ -n "${HUB_CA_FILE}" ]; then
  HELM_ARGS+=(--set-file "authConfiguration.hubIssuer.certificateAuthority=${HUB_CA_FILE}")
fi
if [ -n "${DEX_CA_FILE}" ]; then
  HELM_ARGS+=(--set-file "authConfiguration.dexIssuer.certificateAuthority=${DEX_CA_FILE}")
fi
if [ -n "${DEX_ISSUER_URL}" ]; then
  HELM_ARGS+=(--set "authConfiguration.dexIssuer.url=${DEX_ISSUER_URL}")
fi

helm "${HELM_ARGS[@]}" | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
sys.stdout.write(doc["data"]["authentication-configuration.yaml"])
'
