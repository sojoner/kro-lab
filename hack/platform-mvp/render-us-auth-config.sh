#!/usr/bin/env bash
set -euo pipefail

US_CHART="${1:?usage: render-us-auth-config.sh <path-to-us-chart>}"

helm template us-auth "${US_CHART}" --show-only templates/auth-config.yaml | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
sys.stdout.write(doc["data"]["authentication-configuration.yaml"])
'
