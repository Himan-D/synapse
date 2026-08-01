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

echo "==> workspace tests (recall / metrics / blast)"
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

echo "==> recall HTTP"
curl -sf "http://127.0.0.1:8787/v1/recall?run_id=run_demo&query=risk" | head -c 400
echo

echo "==> metrics HTTP"
curl -sf "http://127.0.0.1:8787/v1/metrics/tool_failure_rate?run_id=run_demo"
echo

echo "==> e2e OK"
