#!/usr/bin/env bash
set -euo pipefail

CHAINSAW_DIR="${CHAINSAW_DIR:-/tests}"
LOKI_URL="${LOKI_URL:-http://loki.monitoring:3100}"
KUBECONFIG_HUB="${KUBECONFIG_HUB:-/kubeconfig/hub}"
KUBECONFIG_US="${KUBECONFIG_US:-/kubeconfig/us}"

echo "==> Starting chainsaw test run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cp "${KUBECONFIG_HUB}" "${CHAINSAW_DIR}/kubeconfig-hub"
cp "${KUBECONFIG_US}"  "${CHAINSAW_DIR}/kubeconfig-us-internal"

REPORT_FILE="${CHAINSAW_DIR}/chainsaw-report.json"
START_NS=$(date +%s%N)

if chainsaw test "${CHAINSAW_DIR}" --report-format JSON --report-name chainsaw-report 2>&1; then
    RESULT="pass"
    EXIT_CODE=0
else
    RESULT="fail"
    EXIT_CODE=1
fi

END_NS=$(date +%s%N)
DURATION_MS=$(((END_NS - START_NS) / 1000000))

TIMESTAMP=$(date -u +%s%N)

if [ -f "${CHAINSAW_DIR}/chainsaw-report.json" ]; then
    REPORT_JSON=$(jq -c . "${CHAINSAW_DIR}/chainsaw-report.json" 2>/dev/null || echo '{}')
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