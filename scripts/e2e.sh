#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> build"
zig build

BIN="$ROOT/zig-out/bin/synapse"
WS="$ROOT/examples/harness"

echo "==> ingest sample events"
"$BIN" ingest harness_events "$WS/sample_events.ndjson" --root "$WS" --replace

echo "==> workspace tests (recall / plan / route / metrics / blast / dispute)"
"$BIN" test --root "$WS"

echo "==> pipe run recall_context"
"$BIN" pipe run recall_context --root "$WS" --run-id run_demo query=risk | head -c 400
echo

echo "==> starting dev server on :8787"
"$BIN" dev --root "$WS" --port 8787 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

echo "==> health"
curl -sf "http://127.0.0.1:8787/health"
echo

echo "==> workspace"
curl -sf "http://127.0.0.1:8787/v1/workspace"
echo

echo "==> recall HTTP"
curl -sf "http://127.0.0.1:8787/v1/recall?run_id=run_demo&query=risk" | head -c 400
echo

echo "==> plan HTTP"
curl -sf "http://127.0.0.1:8787/v1/plan?goal=fix%20risk%20bug&run_id=run_demo" | head -c 400
echo

echo "==> route HTTP"
curl -sf "http://127.0.0.1:8787/v1/route?query=run%20tests&run_id=run_demo" | head -c 400
echo

echo "==> dispute HTTP"
curl -sf "http://127.0.0.1:8787/v1/dispute?run_id=run_demo"
echo

echo "==> metrics HTTP"
curl -sf "http://127.0.0.1:8787/v1/metrics/tool_failure_rate?run_id=run_demo"
echo

echo "==> llm tokens HTTP"
curl -sf "http://127.0.0.1:8787/v1/metrics/llm_tokens?run_id=run_demo"
echo

echo "==> remember HTTP"
curl -sf -X POST "http://127.0.0.1:8787/v1/remember" \
  -H "content-type: application/json" \
  -d '{"run_id":"run_demo","text":"e2e remembered claim","confidence":0.85}'
echo

echo "==> metrics CSV format"
curl -sf "http://127.0.0.1:8787/v1/pipes/tool_failure_rate.csv?run_id=run_demo" | head -c 200
echo

echo "==> query API"
curl -sf -X POST "http://127.0.0.1:8787/v1/query" \
  -H "content-type: application/json" \
  -d '{"datasource":"harness_events","where":{"run_id":"run_demo"},"limit":2}' | head -c 300
echo

echo "==> endpoints list"
curl -sf "http://127.0.0.1:8787/v1/endpoints" | head -c 300
echo

echo "==> graph HTTP"
curl -sf "http://127.0.0.1:8787/v1/graph?run_id=run_demo" | head -c 300
echo

echo "==> embed HTTP"
curl -sf "http://127.0.0.1:8787/v1/embed?run_id=run_demo&query=margin" | head -c 300
echo

echo "==> consolidate HTTP"
curl -sf "http://127.0.0.1:8787/v1/consolidate?run_id=run_demo" | head -c 300
echo

echo "==> checkpoint HTTP"
curl -sf -X POST "http://127.0.0.1:8787/v1/checkpoint" \
  -H "content-type: application/json" \
  -d '{"name":"e2e_baseline","datasource":"harness_events"}'
echo

echo "==> diff HTTP"
curl -sf "http://127.0.0.1:8787/v1/diff?run_a=run_demo&run_b=run_demo" | head -c 300
echo

echo "==> health version"
HEALTH=$(curl -sf "http://127.0.0.1:8787/health")
echo "$HEALTH"
echo "$HEALTH" | grep -q '"version":"0.1.0"'
echo "$HEALTH" | grep -q '"ready":true'

echo "==> request id header"
RID=$(curl -sf -D - -o /dev/null "http://127.0.0.1:8787/health" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-id"{print $2}')
test -n "$RID"
echo "x-request-id=$RID"

echo "==> unsafe checkpoint rejected"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:8787/v1/checkpoint" \
  -H "content-type: application/json" \
  -d '{"name":"../evil","datasource":"harness_events"}')
test "$code" = "400"

echo "==> playground"
curl -sf "http://127.0.0.1:8787/" | head -c 120
echo

echo "==> auth gate"
# Prefer SIGTERM (graceful), then SIGKILL — never block forever on wait.
kill -TERM "$PID" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

TOKEN=$(tr -d '\n' < "$WS/.synapse/token")
SYNAPSE_REQUIRE_AUTH=1 "$BIN" dev --root "$WS" --port 8788 &
PID=$!
sleep 0.5
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8788/v1/recall?run_id=run_demo")
test "$code" = "401"
curl -sf -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8788/v1/recall?run_id=run_demo&query=risk" | head -c 200
echo
curl -sf "http://127.0.0.1:8788/v1/recall?run_id=run_demo&query=risk&token=$TOKEN" | head -c 200
echo

echo "==> e2e OK"
