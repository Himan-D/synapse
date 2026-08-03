#!/usr/bin/env bash
# cloud_bootstrap.sh — stand up a usable Synapse cloud tenant in one shot.
#
#   ./scripts/cloud_bootstrap.sh <data_root> [org_name] [workspace_name]
#
# Creates (idempotently, except for tokens) a platform, an org, a workspace, and
# a workspace token, then prints the secrets and the curl calls that use them.
#
# Secrets are printed exactly once. platform.json stores only SHA-256 digests, so
# a token that scrolls out of your terminal is gone — mint a new one and revoke
# the old with `synapse token revoke <token_id> --data-root <data_root>`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${1:-}"
ORG_NAME="${2:-acme}"
WS_NAME="${3:-production}"
PORT="${PORT:-8787}"

if [ -z "$DATA" ]; then
    echo "usage: $0 <data_root> [org_name] [workspace_name]" >&2
    exit 2
fi

BIN="$ROOT/zig-out/bin/synapse"
if [ ! -x "$BIN" ]; then
    echo "==> building synapse"
    (cd "$ROOT" && zig build)
fi

json_field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

mkdir -p "$DATA"

echo "==> platform init ($DATA)"
PLATFORM_OUT=$("$BIN" platform init --data-root "$DATA")
ADMIN_TOKEN=$(echo "$PLATFORM_OUT" | json_field admin_token || true)
if [ -z "$ADMIN_TOKEN" ]; then
    cat >&2 <<EOF
FAIL: this data root already has a platform, and its admin token is stored hashed,
      so it cannot be reprinted. Use the admin token you saved at first init, or
      bootstrap into a fresh data root.
EOF
    exit 1
fi

echo "==> org create ($ORG_NAME)"
ORG_ID=$("$BIN" org create "$ORG_NAME" --data-root "$DATA" | json_field org_id)
test -n "$ORG_ID" || { echo "FAIL: org create returned no org_id" >&2; exit 1; }

echo "==> workspace create ($WS_NAME)"
WS_ID=$("$BIN" workspace create "$WS_NAME" --org "$ORG_ID" --data-root "$DATA" | json_field workspace_id)
test -n "$WS_ID" || { echo "FAIL: workspace create returned no workspace_id" >&2; exit 1; }

echo "==> token create (${WS_NAME}_api, scope ADMIN)"
WS_TOKEN=$("$BIN" token create "${WS_NAME}_api" --workspace "$WS_ID" --scope ADMIN --data-root "$DATA" | json_field token)
test -n "$WS_TOKEN" || { echo "FAIL: token create returned no token" >&2; exit 1; }

BASE="http://127.0.0.1:$PORT"

cat <<EOF

────────────────────────────────────────────────────────────────────────────
 Synapse cloud is bootstrapped. Copy these now — they are not recoverable.
────────────────────────────────────────────────────────────────────────────

  data root      $DATA
  org            $ORG_ID  ($ORG_NAME)
  workspace      $WS_ID  ($WS_NAME)

  admin token    $ADMIN_TOKEN
  workspace tok  $WS_TOKEN

── Serve ───────────────────────────────────────────────────────────────────

  SYNAPSE_REQUIRE_AUTH=1 $BIN cloud serve \\
      --data-root $DATA --host 127.0.0.1 --port $PORT

  Admin console: $BASE/cloud

── Ingest and read (workspace token) ───────────────────────────────────────

  curl -s -X POST $BASE/v1/w/$WS_ID/events/harness_events \\
      -H "Authorization: Bearer $WS_TOKEN" \\
      -H "content-type: application/x-ndjson" \\
      -d '{"ts":"2026-01-01T00:00:00Z","run_id":"run_demo","agent_id":"agent_1","type":"plan_step","payload":{"task_id":"t1","name":"n1"}}'

  curl -s "$BASE/v1/w/$WS_ID/recall?run_id=run_demo&query=risk" \\
      -H "Authorization: Bearer $WS_TOKEN"

── Control plane (admin token) ─────────────────────────────────────────────

  curl -s $BASE/v1/platform/workspaces -H "Authorization: Bearer $ADMIN_TOKEN"
  curl -s "$BASE/v1/platform/tokens?workspace_id=$WS_ID" -H "Authorization: Bearer $ADMIN_TOKEN"
  curl -s $BASE/v1/platform/usage -H "Authorization: Bearer $ADMIN_TOKEN"

  # revoke by token id (from the tokens listing above)
  curl -s -X POST $BASE/v1/platform/tokens/<token_id>/revoke \\
      -H "Authorization: Bearer $ADMIN_TOKEN"

EOF
