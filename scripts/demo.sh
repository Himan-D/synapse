#!/usr/bin/env bash
# Synapse demo — build → ingest → serve → curl all endpoints → show playground URL
# Usage: ./scripts/demo.sh [PORT]   (default port: 8787)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${1:-8787}"
BIN="$ROOT/zig-out/bin/synapse"
WS="$ROOT/examples/harness"

# ── colours ──────────────────────────────────────────────────────────────────
bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
cyan=$'\033[36m'; green=$'\033[32m'; yellow=$'\033[33m'; blue=$'\033[34m'

step() { echo; echo "${bold}${cyan}▶ $*${reset}"; }
ok()   { echo "${green}  ✓ $*${reset}"; }
show() { echo "${dim}  $*${reset}"; }

trunc() {                        # trunc <max-chars> — reads stdin, prints truncated
  local max="${1:-280}"; local s; s=$(cat)
  if [ "${#s}" -le "$max" ]; then echo "$s"
  else echo "${s:0:$max}… (${#s} chars total)"; fi
}

# ── cleanup trap ─────────────────────────────────────────────────────────────
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo
    show "server stopped (pid $SERVER_PID)"
  fi
}
trap cleanup EXIT

# ── 1. build ─────────────────────────────────────────────────────────────────
step "Build"
if [ -x "$BIN" ] && [ "$BIN" -nt "$ROOT/src/main.zig" ] && [ "$BIN" -nt "$ROOT/build.zig" ]; then
  ok "binary is up-to-date (skip rebuild)"
else
  zig build
  ok "built → $BIN"
fi

# ── 2. ingest sample events ───────────────────────────────────────────────────
step "Ingest sample events into examples/harness"
"$BIN" ingest harness_events "$WS/sample_events.ndjson" --root "$WS" --replace
ok "$(wc -l < "$WS/sample_events.ndjson" | tr -d ' ') events ingested (run_id: run_demo)"

# ── 3. find a free port ───────────────────────────────────────────────────────
find_free_port() {
  local p="$1"
  while lsof -i :"$p" -sTCP:LISTEN -t >/dev/null 2>&1; do
    p=$((p + 1))
  done
  echo "$p"
}
PORT=$(find_free_port "$PORT")

# ── 4. start dev server ───────────────────────────────────────────────────────
step "Start synapse dev on port $PORT"
"$BIN" dev --root "$WS" --port "$PORT" 2>&1 &
SERVER_PID=$!

# wait for server to be ready (up to 5 s)
for i in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "  server exited unexpectedly" >&2; exit 1
  fi
  if [ "$i" -eq 50 ]; then echo "  server did not start in 5 s" >&2; exit 1; fi
done
ok "listening on http://127.0.0.1:$PORT"

# ── 5. health ─────────────────────────────────────────────────────────────────
step "GET /health"
curl -sf "http://127.0.0.1:$PORT/health" | trunc 120
ok "server is healthy"

# ── 6. recall ─────────────────────────────────────────────────────────────────
step "GET /v1/recall  (query: risk)"
OUT=$(curl -sf "http://127.0.0.1:$PORT/v1/recall?run_id=run_demo&query=risk")
echo "$OUT" | trunc 300
ok "recall returned $(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('nodes',[])),' nodes')" 2>/dev/null || echo "response")"

# ── 7. plan ──────────────────────────────────────────────────────────────────
step "GET /v1/plan  (goal: fix risk bug)"
OUT=$(curl -sf "http://127.0.0.1:$PORT/v1/plan?goal=fix%20risk%20bug&run_id=run_demo")
echo "$OUT" | trunc 300
ok "plan returned $(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('steps',[])),' steps')" 2>/dev/null || echo "response")"

# ── 8. route ─────────────────────────────────────────────────────────────────
step "GET /v1/route  (query: run tests)"
OUT=$(curl -sf "http://127.0.0.1:$PORT/v1/route?query=run%20tests&run_id=run_demo")
echo "$OUT" | trunc 300
CHOICE=$(echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choice',{}).get('name','?'))" 2>/dev/null || echo "?")
ok "routed to → $CHOICE"

# ── 9. metrics ────────────────────────────────────────────────────────────────
step "GET /v1/metrics/tool_failure_rate"
OUT=$(curl -sf "http://127.0.0.1:$PORT/v1/metrics/tool_failure_rate?run_id=run_demo")
echo "$OUT" | trunc 300
ok "metrics received"

# ── 10. remember ─────────────────────────────────────────────────────────────
step "POST /v1/remember  (write a Mind claim)"
curl -sf -X POST "http://127.0.0.1:$PORT/v1/remember" \
  -H "content-type: application/json" \
  -d '{"run_id":"run_demo","text":"demo: margin risk is elevated","confidence":0.9}' | trunc 200
ok "claim written"

# ── 11. workflow demo (optional) ──────────────────────────────────────────────
WORKFLOW_DEF="$WS/workflows/demo.workflow.json"
if [ -f "$WORKFLOW_DEF" ]; then
  step "Workflow: start demo run (via HTTP)"
  WF_RES=$(curl -sf -X POST "http://127.0.0.1:$PORT/v1/workflows/demo/runs" \
    -H "content-type: application/json" \
    -d '{"run_id":"wf_demo_run","input":{"source":"demo.sh"}}' 2>/dev/null || echo "{}")
  echo "$WF_RES" | trunc 200
  ok "workflow started (ticking in background — use 'synapse workflow signal' to resume)"
else
  show "(no demo.workflow.json found — skipping workflow demo)"
fi

# ── 12. playground banner ─────────────────────────────────────────────────────
echo
echo "${bold}${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
echo "${bold}${green}  ✔  Synapse demo is running!${reset}"
echo
echo "  ${bold}Open playground${reset}  →  ${yellow}http://127.0.0.1:$PORT/${reset}"
echo "  ${bold}MCP endpoint${reset}     →  ${yellow}http://127.0.0.1:$PORT/v1/mcp${reset}"
echo "  ${bold}API base${reset}         →  ${yellow}http://127.0.0.1:$PORT/v1/${reset}"
echo
echo "  Quick curls:"
echo "    ${dim}curl -s 'http://127.0.0.1:$PORT/v1/recall?run_id=run_demo&query=risk'${reset}"
echo "    ${dim}curl -s 'http://127.0.0.1:$PORT/v1/plan?goal=debug&run_id=run_demo'${reset}"
echo "    ${dim}curl -s 'http://127.0.0.1:$PORT/v1/route?query=grep&run_id=run_demo'${reset}"
echo
echo "  ${dim}Press Ctrl-C to stop the server.${reset}"
echo "${bold}${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"

# keep the server alive until the user interrupts
wait "$SERVER_PID"
