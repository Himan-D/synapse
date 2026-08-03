#!/usr/bin/env bash
# e2e_cloud.sh — end-to-end security and isolation test for cloud (multi-workspace) mode.
#
# Asserts:
#   - no dev-token-local written to cloud-scaffolded workspaces
#   - no token -> 401, not 200
#   - dev-token-local Bearer rejected -> 401
#   - valid token for ws_a on ws_b -> 403 (not 401, not 200)
#   - valid token for ws_a on ws_a -> 200
#   - platform admin token works on control plane; non-admin -> 403
#   - data written to ws_a is NOT visible from ws_b (store isolation)
#   - cloud serve on non-loopback without SYNAPSE_REQUIRE_AUTH=1 exits non-zero
#   - nested control-plane routes (orgs/{org}/workspaces[/{ws}/tokens]) are canonical
#     and validate org->workspace ownership (wrong org -> 404)
#   - flat control-plane aliases still work
#   - scoped (non-admin) tokens are refused on out-of-scope verbs -> 403
#   - CLI-created workspaces are picked up without restarting the server
#   - bare /v1/* routes to the default workspace (--workspace), and 404 without one
#   - platform.json holds no raw token secrets (hash-at-rest)
#   - token listings expose metadata only, never secrets
#   - a revoked token is refused (401) and revocation survives a reload
#   - per-workspace usage counters grow on ingest and recall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> build"
zig build

BIN="$ROOT/zig-out/bin/synapse"
DATA="$ROOT/tmp_e2e_cloud_$$"
SERVER_PID=""
LEGACY_PID=""
FLAGWS_PID=""

stop_pid() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Every spawned server is torn down even if an assertion aborts the script.
cleanup() {
    stop_pid "$SERVER_PID"
    stop_pid "$LEGACY_PID"
    stop_pid "$FLAGWS_PID"
    rm -rf "$DATA"
}
trap cleanup EXIT
rm -rf "$DATA"

assert_code() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL [$label]: expected HTTP $expected, got $actual"
        exit 1
    fi
    echo "ok   [$label]: HTTP $actual"
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -q "$needle"; then
        echo "FAIL [$label]: expected to find '$needle' in: $haystack"
        exit 1
    fi
    echo "ok   [$label]"
}

# ── Platform bootstrap ────────────────────────────────────────────────────────

echo "==> platform init"
PLATFORM_OUT=$("$BIN" platform init --data-root "$DATA")
echo "$PLATFORM_OUT"
ADMIN_TOKEN=$(echo "$PLATFORM_OUT" | grep -o '"admin_token":"[^"]*"' | cut -d'"' -f4)
test -n "$ADMIN_TOKEN" || { echo "FAIL: no admin_token"; exit 1; }

echo "==> org create"
ORG_OUT=$("$BIN" org create acme --data-root "$DATA")
echo "$ORG_OUT"
ORG_ID=$(echo "$ORG_OUT" | grep -o '"org_id":"[^"]*"' | cut -d'"' -f4)
test -n "$ORG_ID" || { echo "FAIL: no org_id"; exit 1; }

echo "==> workspace alpha"
WS_A_OUT=$("$BIN" workspace create alpha --org "$ORG_ID" --data-root "$DATA")
echo "$WS_A_OUT"
WS_A=$(echo "$WS_A_OUT" | grep -o '"workspace_id":"[^"]*"' | cut -d'"' -f4)
test -n "$WS_A" || { echo "FAIL: no workspace_id for alpha"; exit 1; }

echo "==> workspace beta"
WS_B_OUT=$("$BIN" workspace create beta --org "$ORG_ID" --data-root "$DATA")
echo "$WS_B_OUT"
WS_B=$(echo "$WS_B_OUT" | grep -o '"workspace_id":"[^"]*"' | cut -d'"' -f4)
test -n "$WS_B" || { echo "FAIL: no workspace_id for beta"; exit 1; }

echo "==> mint tokens (alpha + beta)"
TOK_A_OUT=$("$BIN" token create writer_a --workspace "$WS_A" --scope ADMIN --data-root "$DATA")
echo "$TOK_A_OUT"
TOK_A=$(echo "$TOK_A_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_A" || { echo "FAIL: no token for alpha"; exit 1; }

TOK_B_OUT=$("$BIN" token create writer_b --workspace "$WS_B" --scope ADMIN --data-root "$DATA")
echo "$TOK_B_OUT"
TOK_B=$(echo "$TOK_B_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_B" || { echo "FAIL: no token for beta"; exit 1; }

# ── Security invariants before server starts ──────────────────────────────────

echo "==> platform.json stores digests, not raw secrets"
test -f "$DATA/platform.json" || { echo "FAIL: no platform.json"; exit 1; }
if grep -q '"token":' "$DATA/platform.json"; then
    echo "FAIL: platform.json still has a plaintext \"token\" field"
    exit 1
fi
if grep -q '"admin_token":' "$DATA/platform.json"; then
    echo "FAIL: platform.json still has a plaintext \"admin_token\" field"
    exit 1
fi
for secret in "$ADMIN_TOKEN" "$TOK_A" "$TOK_B"; do
    if grep -qF "$secret" "$DATA/platform.json"; then
        echo "FAIL: raw secret found in platform.json"
        exit 1
    fi
done
if grep -qE '"(p|sk)\.' "$DATA/platform.json"; then
    echo "FAIL: a raw p./sk. token string is present in platform.json"
    exit 1
fi
grep -q '"admin_token_hash"' "$DATA/platform.json" || { echo "FAIL: no admin_token_hash"; exit 1; }
grep -q '"token_hash"' "$DATA/platform.json" || { echo "FAIL: no token_hash"; exit 1; }
echo "ok   [platform.json is hash-at-rest]"

echo "==> re-running platform init does not reprint the admin token"
REINIT_OUT=$("$BIN" platform init --data-root "$DATA")
echo "$REINIT_OUT" | grep -q '"admin_token":null' || {
    echo "FAIL: second platform init leaked or rotated the admin token: $REINIT_OUT"
    exit 1
}
echo "ok   [admin token shown only at creation]"

echo "==> CLI token list returns metadata, never secrets"
CLI_TOKENS=$("$BIN" token list --workspace "$WS_A" --data-root "$DATA")
echo "$CLI_TOKENS"
assert_contains "CLI token list has token ids" '"id":"tok_' "$CLI_TOKENS"
if echo "$CLI_TOKENS" | grep -qF "$TOK_A"; then
    echo "FAIL: CLI token list leaked the raw secret"
    exit 1
fi
echo "ok   [CLI token list is metadata-only]"

echo "==> no dev-token-local in cloud-scaffolded workspace files"
if grep -r "dev-token-local" "$DATA/workspaces/" 2>/dev/null | grep -q .; then
    echo "FAIL: dev-token-local found in scaffolded workspaces"
    exit 1
fi
echo "ok   [no dev-token-local in workspace dirs]"

echo "==> dev-token-local not in src/"
if grep -r "dev-token-local" "$ROOT/src/" 2>/dev/null | grep -q .; then
    echo "FAIL: dev-token-local still in source files"
    exit 1
fi
echo "ok   [dev-token-local absent from src/]"

echo "==> cloud serve on 0.0.0.0 without SYNAPSE_REQUIRE_AUTH exits non-zero"
non_auth_exit=0
"$BIN" cloud serve --data-root "$DATA" --host 0.0.0.0 --port 8791 2>/dev/null || non_auth_exit=$?
if [ "$non_auth_exit" -eq 0 ]; then
    echo "FAIL: should have exited non-zero when binding 0.0.0.0 without SYNAPSE_REQUIRE_AUTH"
    exit 1
fi
echo "ok   [non-loopback without REQUIRE_AUTH exits non-zero: $non_auth_exit]"

# ── Start authenticated cloud server ─────────────────────────────────────────

echo "==> start cloud server (loopback, SYNAPSE_REQUIRE_AUTH=1)"
SYNAPSE_REQUIRE_AUTH=1 "$BIN" cloud serve --data-root "$DATA" --host 127.0.0.1 --port 8790 &
SERVER_PID=$!
sleep 0.6

echo "==> health (no auth required)"
HEALTH=$(curl -sf "http://127.0.0.1:8790/health")
echo "$HEALTH" | grep -q '"mode":"cloud"' || { echo "FAIL: health missing mode:cloud"; exit 1; }
echo "ok   [health returns mode:cloud]"

# ── Auth matrix ───────────────────────────────────────────────────────────────

echo "==> no token -> 401"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "no token on ws_a" "401" "$code"

echo "==> dev-token-local bearer -> 401"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer dev-token-local" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "dev-token-local rejected" "401" "$code"

echo "==> unknown token -> 401"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer p.totallyunknowntoken" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "unknown token" "401" "$code"

echo "==> ws_a token on ws_b -> 403 (not 401)"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/w/$WS_B/workspace")
assert_code "wrong-workspace token" "403" "$code"

echo "==> ws_a token on ws_a -> 200"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "correct workspace token" "200" "$code"

echo "==> admin token on control plane -> 200"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/workspaces")
assert_code "admin on control plane" "200" "$code"

echo "==> workspace token on control plane -> 403"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/platform/workspaces")
assert_code "workspace token on control plane" "403" "$code"

echo "==> no token on control plane -> 401"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:8790/v1/platform/workspaces")
assert_code "no token on control plane" "401" "$code"

# ── Data isolation ────────────────────────────────────────────────────────────

PROBE_RUN="isolation_probe_$$"

echo "==> ingest events into alpha"
ingest_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://127.0.0.1:8790/v1/w/$WS_A/events/harness_events" \
    -H "Authorization: Bearer $TOK_A" \
    -H "content-type: application/x-ndjson" \
    -d "{\"ts\":\"2026-01-01T00:00:00Z\",\"run_id\":\"$PROBE_RUN\",\"agent_id\":\"agent_1\",\"type\":\"plan_step\",\"payload\":{\"task_id\":\"t1\",\"name\":\"n1\"}}")
assert_code "ingest into alpha" "200" "$ingest_code"

echo "==> beta token cannot read alpha events (isolation)"
BETA_RESP=$(curl -sf \
    -X POST "http://127.0.0.1:8790/v1/w/$WS_B/query" \
    -H "Authorization: Bearer $TOK_B" \
    -H "content-type: application/json" \
    -d "{\"datasource\":\"harness_events\",\"where\":{\"run_id\":\"$PROBE_RUN\"},\"limit\":1}")
echo "$BETA_RESP"
if echo "$BETA_RESP" | grep -q "\"$PROBE_RUN\""; then
    echo "FAIL: data isolation breach — $PROBE_RUN events visible in beta workspace"
    exit 1
fi
echo "ok   [alpha events not visible from beta]"

echo "==> alpha token can read alpha events"
ALPHA_RESP=$(curl -sf \
    -X POST "http://127.0.0.1:8790/v1/w/$WS_A/query" \
    -H "Authorization: Bearer $TOK_A" \
    -H "content-type: application/json" \
    -d "{\"datasource\":\"harness_events\",\"where\":{\"run_id\":\"$PROBE_RUN\"},\"limit\":1}")
echo "$ALPHA_RESP"
echo "$ALPHA_RESP" | grep -q "\"$PROBE_RUN\"" || { echo "FAIL: alpha events not visible from alpha"; exit 1; }
echo "ok   [alpha events visible from alpha]"

# ── Admin token cross-workspace via control plane ─────────────────────────────

echo "==> admin token lists both workspaces (flat alias)"
WS_LIST=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/workspaces")
echo "$WS_LIST" | grep -q "\"$WS_A\"" || { echo "FAIL: ws_a not in platform listing"; exit 1; }
echo "$WS_LIST" | grep -q "\"$WS_B\"" || { echo "FAIL: ws_b not in platform listing"; exit 1; }
echo "ok   [admin sees both workspaces via flat alias]"

# ── Nested control-plane routes ───────────────────────────────────────────────

echo "==> nested GET /v1/platform/orgs/{org_id}/workspaces -> 200"
NESTED_WS=$(curl -sf \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/orgs/$ORG_ID/workspaces")
echo "$NESTED_WS"
echo "$NESTED_WS" | grep -q "\"$WS_A\"" || { echo "FAIL: ws_a not in nested org listing"; exit 1; }
echo "$NESTED_WS" | grep -q "\"$WS_B\"" || { echo "FAIL: ws_b not in nested org listing"; exit 1; }
echo "ok   [nested org workspace list returns both workspaces]"

echo "==> nested GET with wrong org -> 404"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/orgs/org_doesnotexist_xxx/workspaces")
assert_code "nested wrong org" "404" "$code"

echo "==> nested POST /v1/platform/orgs/{org_id}/workspaces creates workspace"
GAMMA_OUT=$(curl -sf -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d '{"name":"gamma"}' \
    "http://127.0.0.1:8790/v1/platform/orgs/$ORG_ID/workspaces")
echo "$GAMMA_OUT"
WS_C=$(echo "$GAMMA_OUT" | grep -o '"workspace_id":"[^"]*"' | cut -d'"' -f4)
test -n "$WS_C" || { echo "FAIL: no workspace_id for gamma"; exit 1; }
echo "ok   [nested workspace create returned workspace_id=$WS_C]"

echo "==> nested POST with wrong org -> 404"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d '{"name":"delta"}' \
    "http://127.0.0.1:8790/v1/platform/orgs/org_wrongone_xxx/workspaces")
assert_code "nested wrong org workspace create" "404" "$code"

echo "==> nested POST /v1/platform/orgs/{org_id}/workspaces/{ws_id}/tokens mints token"
TOK_C_OUT=$(curl -sf -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d '{"name":"gamma_writer","scope":"EVENTS:WRITE"}' \
    "http://127.0.0.1:8790/v1/platform/orgs/$ORG_ID/workspaces/$WS_C/tokens")
echo "$TOK_C_OUT"
TOK_C=$(echo "$TOK_C_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_C" || { echo "FAIL: no token returned for gamma"; exit 1; }
echo "ok   [nested token mint returned token for gamma]"

echo "==> nested token mint with wrong org -> 404"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d '{"name":"evil","scope":"ADMIN"}' \
    "http://127.0.0.1:8790/v1/platform/orgs/org_wrongone_xxx/workspaces/$WS_C/tokens")
assert_code "nested wrong org token mint" "404" "$code"

echo "==> nested token mint with unknown scope -> 400"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d '{"name":"t","scope":"MIND:READ"}' \
    "http://127.0.0.1:8790/v1/platform/orgs/$ORG_ID/workspaces/$WS_C/tokens")
assert_code "unknown scope MIND:READ rejected" "400" "$code"

echo "==> gamma token (EVENTS:WRITE) can ingest events"
ingest_c=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://127.0.0.1:8790/v1/w/$WS_C/events/harness_events" \
    -H "Authorization: Bearer $TOK_C" \
    -H "content-type: application/x-ndjson" \
    -d '{"ts":"2026-01-01T00:00:00Z","run_id":"gamma_run","agent_id":"a","type":"plan_step","payload":{"task_id":"t1","name":"n1"}}')
assert_code "gamma EVENTS:WRITE ingest" "200" "$ingest_c"

# ── Legacy /v1/* routing via default workspace ────────────────────────────────

echo "==> gamma EVENTS:WRITE token cannot use an admin verb -> 403"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://127.0.0.1:8790/v1/w/$WS_C/reload" \
    -H "Authorization: Bearer $TOK_C")
assert_code "EVENTS:WRITE token on admin verb" "403" "$code"

# ── CLI-created workspace served without a restart (platform.json mtime watch) ─

echo "==> workspace created by the CLI is served without restarting the server"
WS_D_OUT=$("$BIN" workspace create delta --org "$ORG_ID" --data-root "$DATA")
echo "$WS_D_OUT"
WS_D=$(echo "$WS_D_OUT" | grep -o '"workspace_id":"[^"]*"' | cut -d'"' -f4)
test -n "$WS_D" || { echo "FAIL: no workspace_id for delta"; exit 1; }
TOK_D=$("$BIN" token create writer_d --workspace "$WS_D" --scope ADMIN --data-root "$DATA" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_D" || { echo "FAIL: no token for delta"; exit 1; }
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_D" \
    "http://127.0.0.1:8790/v1/w/$WS_D/workspace")
assert_code "CLI-created workspace hot-reloaded" "200" "$code"

# ── Token listing and revocation ──────────────────────────────────────────────

echo "==> GET /v1/platform/tokens?workspace_id= returns metadata only"
TOKEN_LIST=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/tokens?workspace_id=$WS_A")
echo "$TOKEN_LIST"
assert_contains "token listing has ids" '"id":"tok_' "$TOKEN_LIST"
assert_contains "token listing has revoked flag" '"revoked":false' "$TOKEN_LIST"
if echo "$TOKEN_LIST" | grep -qF "$TOK_A"; then
    echo "FAIL: token listing leaked a raw secret"
    exit 1
fi
if echo "$TOKEN_LIST" | grep -q "\"$WS_B\""; then
    echo "FAIL: workspace_id filter leaked another workspace's tokens"
    exit 1
fi
echo "ok   [token listing is metadata-only and filtered]"

echo "==> mint a throwaway token, revoke it over HTTP, confirm it stops working"
REVOKE_OUT=$(curl -sf -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d "{\"workspace_id\":\"$WS_A\",\"name\":\"doomed\",\"scope\":\"ADMIN\"}" \
    "http://127.0.0.1:8790/v1/platform/tokens")
echo "$REVOKE_OUT"
TOK_R=$(echo "$REVOKE_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
TOK_R_ID=$(echo "$REVOKE_OUT" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_R" -a -n "$TOK_R_ID" || { echo "FAIL: mint did not return token + id"; exit 1; }

code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_R" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "fresh token works before revoke" "200" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/tokens/$TOK_R_ID/revoke")
assert_code "revoke returns 200" "200" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_R" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "revoked token rejected" "401" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:8790/v1/platform/tokens/tok_doesnotexist/revoke")
assert_code "revoke unknown token id" "404" "$code"

echo "==> CLI revoke is picked up by the running server"
TOK_CLI_OUT=$("$BIN" token create cli_doomed --workspace "$WS_A" --scope ADMIN --data-root "$DATA")
TOK_CLI=$(echo "$TOK_CLI_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
TOK_CLI_ID=$(echo "$TOK_CLI_OUT" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
test -n "$TOK_CLI" -a -n "$TOK_CLI_ID" || { echo "FAIL: CLI mint did not return token + id"; exit 1; }
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_CLI" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "CLI-minted token works" "200" "$code"
"$BIN" token revoke "$TOK_CLI_ID" --data-root "$DATA"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_CLI" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "CLI-revoked token rejected without restart" "401" "$code"

echo "==> revoked tokens stay revoked on disk"
grep -q '"revoked":true' "$DATA/platform.json" || { echo "FAIL: revocation not persisted"; exit 1; }
echo "ok   [revocation persisted to platform.json]"

# ── Usage metering ────────────────────────────────────────────────────────────

usage_field() {
    python3 -c '
import json, sys
doc = json.loads(sys.argv[1])
for w in doc.get("workspaces", []):
    if w.get("workspace_id") == sys.argv[2]:
        print(w.get(sys.argv[3], 0))
        break
else:
    print(0)
' "$1" "$2" "$3"
}

echo "==> usage counters exist for alpha"
USAGE_BEFORE=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:8790/v1/platform/usage")
echo "$USAGE_BEFORE"
REQ_BEFORE=$(usage_field "$USAGE_BEFORE" "$WS_A" requests)
EVENTS_BEFORE=$(usage_field "$USAGE_BEFORE" "$WS_A" ingest_events)
BYTES_BEFORE=$(usage_field "$USAGE_BEFORE" "$WS_A" ingest_bytes)
[ "$REQ_BEFORE" -gt 0 ] || { echo "FAIL: no requests counted for alpha"; exit 1; }
echo "ok   [alpha usage: requests=$REQ_BEFORE events=$EVENTS_BEFORE bytes=$BYTES_BEFORE]"

echo "==> ingest + recall increase alpha's counters"
curl -sf -o /dev/null -X POST "http://127.0.0.1:8790/v1/w/$WS_A/events/harness_events" \
    -H "Authorization: Bearer $TOK_A" \
    -H "content-type: application/x-ndjson" \
    -d "{\"ts\":\"2026-01-01T00:00:01Z\",\"run_id\":\"$PROBE_RUN\",\"agent_id\":\"agent_1\",\"type\":\"plan_step\",\"payload\":{\"task_id\":\"t2\",\"name\":\"n2\"}}"
curl -sf -o /dev/null -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/w/$WS_A/recall?run_id=$PROBE_RUN&query=risk"

USAGE_AFTER=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:8790/v1/platform/usage")
echo "$USAGE_AFTER"
REQ_AFTER=$(usage_field "$USAGE_AFTER" "$WS_A" requests)
EVENTS_AFTER=$(usage_field "$USAGE_AFTER" "$WS_A" ingest_events)
BYTES_AFTER=$(usage_field "$USAGE_AFTER" "$WS_A" ingest_bytes)
[ "$REQ_AFTER" -gt "$REQ_BEFORE" ] || { echo "FAIL: requests did not increase ($REQ_BEFORE -> $REQ_AFTER)"; exit 1; }
[ "$EVENTS_AFTER" -gt "$EVENTS_BEFORE" ] || { echo "FAIL: ingest_events did not increase ($EVENTS_BEFORE -> $EVENTS_AFTER)"; exit 1; }
[ "$BYTES_AFTER" -gt "$BYTES_BEFORE" ] || { echo "FAIL: ingest_bytes did not increase ($BYTES_BEFORE -> $BYTES_AFTER)"; exit 1; }
echo "ok   [alpha usage grew: requests $REQ_BEFORE->$REQ_AFTER events $EVENTS_BEFORE->$EVENTS_AFTER bytes $BYTES_BEFORE->$BYTES_AFTER]"

echo "==> usage is persisted and per-workspace"
test -f "$DATA/usage.json" || { echo "FAIL: usage.json not written"; exit 1; }
grep -q "\"$WS_A\"" "$DATA/usage.json" || { echo "FAIL: alpha missing from usage.json"; exit 1; }
BETA_EVENTS=$(usage_field "$USAGE_AFTER" "$WS_B" ingest_events)
[ "$BETA_EVENTS" -eq 0 ] || { echo "FAIL: beta was charged for alpha's ingest"; exit 1; }
echo "ok   [usage.json persisted; beta not charged for alpha's ingest]"

echo "==> usage requires an admin token"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/platform/usage")
assert_code "workspace token on usage" "403" "$code"

# ── Cloud admin console ───────────────────────────────────────────────────────

echo "==> /cloud serves the admin console"
CLOUD_HTML=$(curl -sf "http://127.0.0.1:8790/cloud")
assert_contains "/cloud is the admin console" "SYNAPSE CLOUD" "$CLOUD_HTML"
CLOUD_HTML_ALT=$(curl -sf "http://127.0.0.1:8790/ui/cloud")
assert_contains "/ui/cloud is the same console" "SYNAPSE CLOUD" "$CLOUD_HTML_ALT"
if echo "$CLOUD_HTML" | grep -qE '(p|sk)\.[0-9a-f]{32}'; then
    echo "FAIL: /cloud page embeds a token"
    exit 1
fi
echo "ok   [/cloud ships no secrets]"

# ── Legacy /v1/* routing via default workspace ────────────────────────────────

echo "==> start second cloud server with SYNAPSE_WORKSPACE=$WS_A (legacy path test)"
SYNAPSE_REQUIRE_AUTH=1 SYNAPSE_WORKSPACE="$WS_A" \
    "$BIN" cloud serve --data-root "$DATA" --host 127.0.0.1 --port 8793 &
LEGACY_PID=$!
sleep 0.6

echo "==> legacy /v1/workspace with valid token on default workspace -> 200"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8793/v1/workspace")
assert_code "legacy /v1/workspace with default workspace" "200" "$code"

echo "==> legacy /v1/workspace no token -> 401"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:8793/v1/workspace")
assert_code "legacy /v1/workspace no token" "401" "$code"

echo "==> legacy /v1/workspace ws_b token on ws_a default -> 403"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_B" \
    "http://127.0.0.1:8793/v1/workspace")
assert_code "legacy /v1/workspace wrong workspace token" "403" "$code"

echo "==> /v1/workspace without SYNAPSE_WORKSPACE set -> 404"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8790/v1/workspace")
assert_code "no default workspace -> 404" "404" "$code"

echo "==> legacy /v1/* serves the default workspace's own data"
LEGACY_RESP=$(curl -sf -X POST "http://127.0.0.1:8793/v1/query" \
    -H "Authorization: Bearer $TOK_A" \
    -H "content-type: application/json" \
    -d "{\"datasource\":\"harness_events\",\"where\":{\"run_id\":\"$PROBE_RUN\"},\"limit\":1}")
echo "$LEGACY_RESP"
assert_contains "legacy path resolves to alpha's store" "\"$PROBE_RUN\"" "$LEGACY_RESP"

stop_pid "$LEGACY_PID"
LEGACY_PID=""

echo "==> --workspace flag sets the default workspace (takes precedence over env)"
SYNAPSE_REQUIRE_AUTH=1 SYNAPSE_WORKSPACE="$WS_B" \
    "$BIN" cloud serve --data-root "$DATA" --host 127.0.0.1 --port 8794 --workspace "$WS_A" &
FLAGWS_PID=$!
sleep 0.6

code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_A" \
    "http://127.0.0.1:8794/v1/workspace")
assert_code "--workspace flag overrides SYNAPSE_WORKSPACE" "200" "$code"

code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOK_B" \
    "http://127.0.0.1:8794/v1/workspace")
assert_code "env-var workspace token rejected when flag wins" "403" "$code"

stop_pid "$FLAGWS_PID"
FLAGWS_PID=""

# ── Token expiry ──────────────────────────────────────────────────────────────

echo "==> mint token with ttl_seconds"
TTL_OUT=$(curl -sf -X POST "http://127.0.0.1:8790/v1/platform/tokens" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "content-type: application/json" \
    -d "{\"workspace_id\":\"$WS_A\",\"name\":\"short-lived\",\"scope\":\"ADMIN\",\"ttl_seconds\":30}")
echo "$TTL_OUT"
assert_contains "ttl mint includes expires_at" '"expires_at":' "$TTL_OUT"
TTL_TOK=$(echo "$TTL_OUT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
test -n "$TTL_TOK" || { echo "FAIL: no ttl token"; exit 1; }

echo "==> ttl token works immediately"
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TTL_TOK" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "ttl token before expiry" "200" "$code"

echo "==> wait for token expiry"
sleep 31
code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TTL_TOK" \
    "http://127.0.0.1:8790/v1/w/$WS_A/workspace")
assert_code "expired token rejected" "401" "$code"

echo "==> token list shows expires_at"
LIST_TOKENS=$(curl -sf "http://127.0.0.1:8790/v1/platform/tokens?workspace_id=$WS_A" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
assert_contains "token list has expires_at" '"expires_at":' "$LIST_TOKENS"

# ── Platform audit log ────────────────────────────────────────────────────────

echo "==> audit log records control-plane actions"
AUDIT=$(curl -sf "http://127.0.0.1:8790/v1/platform/audit" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
echo "$AUDIT"
assert_contains "audit has token_mint" 'token_mint' "$AUDIT"
assert_contains "audit has token_revoke" 'token_revoke' "$AUDIT"
if echo "$AUDIT" | grep -qE '"(token|admin_token)":'; then
    echo "FAIL: audit log leaked a raw secret"
    exit 1
fi
echo "ok   [audit redacts secrets]"

# ── Soft quotas (429 on ingest + requests) ───────────────────────────────────

echo "==> restart server with soft quotas"
stop_pid "$SERVER_PID"
SERVER_PID=""
SYNAPSE_REQUIRE_AUTH=1 \
    SYNAPSE_QUOTA_INGEST_EVENTS=5 \
    SYNAPSE_QUOTA_REQUESTS=10 \
    "$BIN" cloud serve --data-root "$DATA" --host 127.0.0.1 --port 8790 &
SERVER_PID=$!
sleep 0.6

echo "==> ingest until quota exceeded -> 429"
for i in 1 2 3 4 5 6; do
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://127.0.0.1:8790/v1/w/$WS_B/events/harness_events" \
        -H "Authorization: Bearer $TOK_B" \
        -H "content-type: application/x-ndjson" \
        --data-binary "{\"ts\":\"2026-01-01T00:00:00Z\",\"run_id\":\"quota_test_$i\",\"agent_id\":\"agent_q\",\"type\":\"plan_step\",\"payload\":{\"task_id\":\"t$i\",\"name\":\"n$i\"}}")
    if [ "$i" -le 5 ]; then
        assert_code "ingest $i within quota" "200" "$code"
    else
        assert_code "ingest over quota" "429" "$code"
    fi
done

echo "==> e2e_cloud OK"
