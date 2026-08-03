#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> build"
zig build

BIN="$ROOT/zig-out/bin/synapse"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> ops init in $TMP"
SYNAPSE_BIN="$BIN" "$BIN" ops init --root "$TMP" --base-url "http://127.0.0.1:8787"

test -f "$TMP/.synapse/ops.json"
test -f "$TMP/.synapse/ops.CURSOR.md"
test -f "$TMP/.synapse/ops.mcp.json"
test -f "$TMP/.cursor/hooks.json"
test -f "$TMP/workspace.json"

echo "==> ops.json has enabled:true"
grep -q '"enabled": true' "$TMP/.synapse/ops.json" || grep -q '"enabled":true' "$TMP/.synapse/ops.json"

echo "==> hooks.json references harness_events"
grep -q 'harness_events' "$TMP/.cursor/hooks.json"

echo "==> mcp.json references ops mcp"
grep -q '"ops"' "$TMP/.synapse/ops.mcp.json"
grep -q 'mcp' "$TMP/.synapse/ops.mcp.json"

echo "==> ingest one tool_call event"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TMP/event.ndjson" <<EOF
{"ts":"$TS","run_id":"run_e2e_ops","agent_id":"e2e-agent","type":"tool_call","payload":{"name":"test_tool","ok":true,"latency_ms":1}}
EOF
"$BIN" ingest harness_events "$TMP/event.ndjson" --root "$TMP"

echo "==> ops status"
STATUS="$("$BIN" ops status --root "$TMP")"
echo "$STATUS"
echo "$STATUS" | grep -q '"ops_config":true'
echo "$STATUS" | grep -q '"hooks_installed":true'
echo "$STATUS" | grep -q '"mcp_config_present":true'
echo "$STATUS" | grep -q '"capture_enabled":true'
echo "$STATUS" | grep -q 'e2e-agent'
echo "$STATUS" | grep -q '"last_event_ts"'

echo "==> ops watch (graceful skip without transcript dir)"
WATCH_OUT="$("$BIN" ops watch --root "$TMP" 2>/dev/null || true)"
echo "$WATCH_OUT"
echo "$WATCH_OUT" | grep -q 'no_transcript_dir\|transcripts'

echo "==> start dev server"
"$BIN" dev --root "$TMP" --port 8791 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

echo "==> activity API"
ACTIVITY="$(curl -sf 'http://127.0.0.1:8791/v1/ops/activity?agent_id=e2e-agent&limit=10')"
echo "$ACTIVITY"
echo "$ACTIVITY" | grep -q 'e2e-agent'
echo "$ACTIVITY" | grep -q 'test_tool'

echo "==> e2e_ops OK"
