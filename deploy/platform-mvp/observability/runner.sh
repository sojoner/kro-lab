#!/usr/bin/env bash
set -euo pipefail

BUNDLED_DIR="${BUNDLED_DIR:-/tests-bundled}"
CONFIGMAP_DIR="${CONFIGMAP_DIR:-/tests}"
LOKI_URL="${LOKI_URL:-http://loki.monitoring:3100}"
KUBECONFIG_HUB="${KUBECONFIG_HUB:-/kubeconfig/hub}"
KUBECONFIG_US="${KUBECONFIG_US:-/kubeconfig/us}"

echo "==> Starting chainsaw test run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "${WORKDIR}/tests"

# Prefer bundled tests (image), fallback to ConfigMap
if [ -d "${BUNDLED_DIR}" ] && [ "$(ls -A "${BUNDLED_DIR}" 2>/dev/null)" ]; then
    echo "==> Using bundled tests from ${BUNDLED_DIR}"
    cp -r "${BUNDLED_DIR}"/* "${WORKDIR}/tests/"
elif [ -d "${CONFIGMAP_DIR}" ]; then
    echo "==> Using ConfigMap tests from ${CONFIGMAP_DIR}"
    for f in "${CONFIGMAP_DIR}"/*.yaml; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        name="${base%.yaml}"
        case "$name" in .chainsaw) continue ;; esac
        mkdir -p "${WORKDIR}/tests/${name}"
        sed -e '/^[[:space:]]*count:/d' "$f" > "${WORKDIR}/tests/${name}/chainsaw-test.yaml"
    done
else
    echo "ERROR: no test files found"
    exit 1
fi

cp "${KUBECONFIG_HUB}" "${WORKDIR}/kubeconfig-hub"
cp "${KUBECONFIG_US}"  "${WORKDIR}/kubeconfig-us-internal"

cat > "${WORKDIR}/tests/.chainsaw.yaml" <<EOF
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Configuration
metadata:
  name: platform-mvp
spec:
  timeouts:
    apply: 30s
    assert: 60s
    cleanup: 30s
    delete: 30s
    error: 10s
    exec: 5m
  failFast: false
  parallel: 1
  skipDelete: false
  reportFormat: JSON
  reportName: chainsaw-report
  fullName: true
EOF

cat >> "${WORKDIR}/tests/.chainsaw.yaml" <<EOF
  clusters:
    hub:
      kubeconfig: ${WORKDIR}/kubeconfig-hub
    us:
      kubeconfig: ${WORKDIR}/kubeconfig-us-internal
EOF

cd "${WORKDIR}/tests"
START_NS=$(date +%s%N)

if chainsaw test . \
    --config .chainsaw.yaml \
    --report-format JSON \
    --report-name chainsaw-report 2>&1; then
    RESULT="pass"
    EXIT_CODE=0
else
    RESULT="fail"
    EXIT_CODE=1
fi

END_NS=$(date +%s%N)
DURATION_MS=$(((END_NS - START_NS) / 1000000))

TIMESTAMP=$(date -u +%s%N)

if [ -f "chainsaw-report.json" ]; then
    REPORT_JSON=$(jq -c . "chainsaw-report.json" 2>/dev/null || echo '{}')
elif [ -f "${WORKDIR}/tests/chainsaw-report.json" ]; then
    REPORT_JSON=$(jq -c . "${WORKDIR}/tests/chainsaw-report.json" 2>/dev/null || echo '{}')
else
    REPORT_JSON='{"error":"report not found"}'
fi

LOG_ENTRY=$(jq -n \
    --arg result "${RESULT}" \
    --arg duration "${DURATION_MS}" \
    --argjson report "${REPORT_JSON}" \
    '{
        test_run: true,
        result: $result,
        duration_ms: $duration | tonumber,
        report: $report
    }')

curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST "${LOKI_URL}/loki/api/v1/push" \
    -d "$(jq -n \
        --arg ts "${TIMESTAMP}" \
        --argjson entry "${LOG_ENTRY}" \
        '{
            streams: [{
                stream: { job: "chainsaw-runner" },
                values: [[$ts, ($entry | tostring)]]
            }]
        }')" || true

echo "==> Chainsaw run: ${RESULT} (${DURATION_MS}ms)"
exit "${EXIT_CODE}"