#!/usr/bin/env bash
# Validates all three signals end-to-end via each backend's own API, using
# a single persistent in-cluster debug pod (avoids kubectl port-forward
# timing flakiness and kubectl run --rm's stdout-noise issues).
set -uo pipefail

MON_NS="${1:-observability}"
POD=validate-debug

cleanup() {
  kubectl -n "$MON_NS" delete pod "$POD" --ignore-not-found --now >/dev/null 2>&1
}
trap cleanup EXIT

kubectl -n "$MON_NS" run "$POD" --restart=Never --image=curlimages/curl --command -- sleep 300 >/dev/null 2>&1
kubectl -n "$MON_NS" wait --for=condition=ready pod/"$POD" --timeout=30s >/dev/null 2>&1

kexec() { kubectl -n "$MON_NS" exec "$POD" -- "$@" 2>/dev/null; }

echo "=== TRACES (Tempo) ==="
TRACE_RESULT=$(kexec curl -s --retry 3 --retry-delay 2 "http://tempo.$MON_NS.svc.cluster.local:3200/api/search?tags=service.name%3Dkong-gateway&limit=5")
echo "$TRACE_RESULT" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    traces = d.get('traces', [])
    print(f'PASS: found {len(traces)} trace(s) for service.name=kong-gateway' if traces else 'FAIL: no traces found')
except Exception as e:
    print(f'FAIL: could not parse Tempo response ({e})')
"

echo ""
echo "=== LOGS (Loki, structured OTLP access logs) ==="
LOG_RESULT=$(kexec curl -s --retry 3 --retry-delay 2 -G "http://loki-gateway.$MON_NS.svc.cluster.local/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="kong-gateway"}' \
  --data-urlencode 'limit=5')
echo "$LOG_RESULT" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    results = d.get('data', {}).get('result', [])
    print(f'PASS: found {len(results)} log stream(s) for service_name=kong-gateway' if results else 'FAIL: no logs found — response: ' + json.dumps(d)[:400])
except Exception as e:
    print(f'FAIL: could not parse Loki response ({e})')
"

echo ""
echo "=== LOGS (Loki, raw pod stdout via Alloy) ==="
RAW_LOG_RESULT=$(kexec curl -s --retry 3 --retry-delay 2 -G "http://loki-gateway.$MON_NS.svc.cluster.local/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="kong"}' \
  --data-urlencode 'limit=5')
echo "$RAW_LOG_RESULT" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    results = d.get('data', {}).get('result', [])
    print(f'PASS: found {len(results)} log stream(s) for namespace=kong' if results else 'FAIL: no logs found — response: ' + json.dumps(d)[:400])
except Exception as e:
    print(f'FAIL: could not parse Loki response ({e})')
"

echo ""
echo "=== METRICS (Prometheus) ==="
METRIC_RESULT=$(kexec curl -s --retry 3 --retry-delay 2 "http://kube-prometheus-stack-prometheus.$MON_NS.svc.cluster.local:9090/api/v1/query?query=kong_http_requests_total")
echo "$METRIC_RESULT" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    results = d.get('data', {}).get('result', [])
    print(f'PASS: found {len(results)} kong_http_requests_total series' if results else 'FAIL: no kong_http_requests_total series found')
except Exception as e:
    print(f'FAIL: could not parse Prometheus response ({e})')
"

echo ""
echo "=== Prometheus target health for kong job ==="
kexec curl -s "http://kube-prometheus-stack-prometheus.$MON_NS.svc.cluster.local:9090/api/v1/targets" | python3 -c "
import json,sys
d = json.load(sys.stdin)
found = False
for t in d['data']['activeTargets']:
    if 'kong' in (t['labels'].get('job') or '').lower():
        found = True
        print(f\"  {t['labels']['job']}  {t['scrapeUrl']}  health={t['health']}  lastError={t.get('lastError','')}\")
if not found:
    print('  ABSENT — no kong-related target registered at all (this is the silent-failure symptom when the ServiceMonitor release label is missing)')
"
