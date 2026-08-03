# Synapse Cloud — Deploy Guide

> **Phase C — beta.** Multi-workspace cloud serving, the control plane, and the
> CLI described here are implemented and covered by `scripts/e2e_cloud.sh`.
> Beta means the HTTP contract is stable but has less production mileage than
> local single-root mode. See [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md) for what
> is still open.

---

## Contents

1. [Architecture overview](#1-architecture-overview)
2. [URL routing map](#2-url-routing-map)
3. [Deploy to Render (Blueprint)](#3-deploy-to-render-blueprint)
4. [Environment variables reference](#4-environment-variables-reference)
5. [First-run bootstrap (platform init)](#5-first-run-bootstrap-platform-init)
6. [Migrate from single-root local](#6-migrate-from-single-root-local)
7. [Local Docker smoke test](#7-local-docker-smoke-test)
8. [Security model](#8-security-model)
9. [Storage seams (today → later)](#9-storage-seams-today--later)

---

## 1. Architecture overview

```
SDK / CLI / MCP
      │
      ▼
HTTP Gateway  (0.0.0.0:$PORT)
      │
      ├─ /health  /ready            ← no auth required
      ├─ /v1/platform/…             ← control-plane (admin token)
      ├─ /v1/w/{workspace_id}/…     ← scoped to one workspace (workspace token)
      └─ /v1/…                      ← default workspace (legacy / single-root compat)
```

One `synapse cloud serve` process handles many workspaces.  
Workspace data lives in `$SYNAPSE_DATA_ROOT/workspaces/{workspace_id}/`.  
Platform catalog (orgs, workspaces, tokens) lives in `$SYNAPSE_DATA_ROOT/platform.json`.

---

## 2. URL routing map

| Mode | Path prefix | Auth token scope | Description |
|---|---|---|---|
| **Legacy / single-root** | `/v1/*` | token for the default workspace, or admin | Compat shim — same verbs as `synapse dev`. Requires a default workspace (see below), otherwise `404`. |
| **Multi-workspace** | `/v1/w/{workspace_id}/*` | workspace-scoped token | All verbs scoped to one workspace |
| **Control plane** | `/v1/platform/*` | admin token | Org/workspace/token management |
| **Probes** | `/health`, `/ready` | none | Liveness + readiness |

### Verb → path examples

```
# Default workspace (single-root compat)
GET  /v1/recall?run_id=…&query=…
POST /v1/events/{datasource}
POST /v1/remember
GET  /v1/plan?goal=…
GET  /v1/route?query=…
POST /v1/mcp

# Workspace-scoped (multi-tenant)
GET  /v1/w/acme-prod/recall?run_id=…&query=…
POST /v1/w/acme-prod/events/{datasource}
POST /v1/w/acme-prod/remember
GET  /v1/w/acme-prod/plan?goal=…
POST /v1/w/acme-prod/mcp
GET  /v1/w/acme-prod/pipes/{name}
POST /v1/w/acme-prod/checkpoint

# Control plane — canonical (nested)
GET  /v1/platform/orgs
POST /v1/platform/orgs
GET  /v1/platform/orgs/{org_id}/workspaces
POST /v1/platform/orgs/{org_id}/workspaces
POST /v1/platform/orgs/{org_id}/workspaces/{workspace_id}/tokens

# Control plane — flat aliases (still supported; prefer the nested routes above)
GET  /v1/platform/workspaces
POST /v1/platform/workspaces          # body carries org_id
POST /v1/platform/tokens              # body carries workspace_id
```

The nested routes are canonical because they validate the org→workspace
relationship: minting a token under an `org_id` that does not own
`{workspace_id}` returns `404`, so a stale or guessed workspace id cannot be
attached to the wrong org.

**Token scoping rules:**
- An **admin token** (`platform.json` → `admin_token`) may call any path, including the control plane.
- A **workspace-scoped token** carries one scope and one `workspace_id`. Requests to `/v1/w/{id}/*` must match that id — mismatch → `403`.
- Valid scopes: `ADMIN`, `PIPES:READ`, `EVENTS:WRITE`, `REMEMBER:WRITE`, `QUERY:READ`. Anything else is rejected at mint time with `400 unknown_scope`.
- `SYNAPSE_REQUIRE_AUTH=1` is always set in the Docker image — `Authorization: Bearer <token>` or `?token=` required.

### Default workspace for legacy `/v1/*`

Bare `/v1/*` requests carry no workspace in the URL, so the server needs to be
told which workspace they mean:

```bash
synapse cloud serve --data-root /data --workspace <workspace_id>
# or
SYNAPSE_WORKSPACE=<workspace_id> synapse cloud serve --data-root /data
```

The `--workspace` flag wins over `SYNAPSE_WORKSPACE`. With neither set, `/v1/*`
returns `404` with a hint — it does not silently pick a workspace. Requests then
still need a token valid for that workspace: a token bound elsewhere gets `403`.

---

## 3. Deploy to Render (Blueprint)

### Option A — One-click blueprint

1. Fork or push this repo to GitHub/GitLab.
2. Go to **Render dashboard → New → Blueprint**.
3. Point it at your repo root (`render.yaml` is at the root).
4. Render detects the blueprint and creates:
   - A **Web Service** (`synapse`) with Docker runtime.
   - A **10 GiB persistent disk** mounted at `/data`.
5. Click **Apply** → first deploy begins.
6. Wait for `/health` to return `200` (shown in Render logs).
7. Copy the service URL (e.g. `https://synapse-xxxx.onrender.com`).

### Option B — Manual service setup

```
Runtime:           Docker
Dockerfile path:   ./Dockerfile
Health check path: /health
Plan:              Starter (or Standard for production)
```

Environment variables to set in the Render dashboard:

| Variable | Value |
|---|---|
| `SYNAPSE_REQUIRE_AUTH` | `1` |
| `SYNAPSE_DATA_ROOT` | `/data` |
| `SYNAPSE_RATE_LIMIT` | `100` *(optional)* |

Add a **disk** → mount path `/data`, size 10 GiB.

### Post-deploy: bootstrap the platform

After first deploy, SSH into the Render service shell (or use `render shell`) and run:

```bash
# Initialize the platform catalog (creates platform.json in /data)
synapse platform init --data-root /data

# Create your first org
synapse org create my-org --data-root /data
# → prints org_id

# Create a workspace
synapse workspace create my-workspace --org <org_id> --data-root /data
# → prints workspace_id

# Mint a scoped token for this workspace
synapse token create ingest --workspace <workspace_id> --scope EVENTS:WRITE --data-root /data
# → prints token (store it securely; it is not recoverable from the server)
```

`synapse platform init` prints the platform `admin_token`. That token is the only
credential that can reach `/v1/platform/*`, so capture it on first run.

The running server watches `platform.json` and picks up orgs, workspaces, and
tokens created by a separate CLI process on the next request — no restart or
redeploy needed. Anything you can do with the CLI you can also do over the
control-plane HTTP API with the admin token (see §2).

---

## 4. Environment variables reference

| Variable | Default (image) | Description |
|---|---|---|
| `PORT` | `8787` | TCP port to bind; Render injects this automatically |
| `SYNAPSE_HOST` | `0.0.0.0` | Bind address; never change in production |
| `SYNAPSE_DATA_ROOT` | `/data` | Workspace + platform data root |
| `SYNAPSE_REQUIRE_AUTH` | `1` | Require Bearer token on all routes |
| `SYNAPSE_RATE_LIMIT` | *(unset)* | Per-token request rate limit (req/s) |

---

## 5. First-run bootstrap (platform init)

The platform catalog stores orgs, workspaces, and tokens in `$SYNAPSE_DATA_ROOT/platform.json`. This file is created by `synapse platform init`.

On a fresh Render deploy with an empty disk, `cloud serve` still starts and
serves `/health` and `/ready` — so the Render health check passes — but logs a
warning naming the missing file, and every workspace route returns `404` until a
workspace exists. Because the server watches `platform.json`, running
`platform init` from the Render shell takes effect on the next request; no
redeploy is required.

**Directory layout after init:**

```
/data/
├── platform.json            ← org/workspace/token catalog (schema-versioned)
└── workspaces/
    └── {workspace_id}/
        ├── workspace.json   ← workspace metadata
        ├── pipes/           ← pipe definitions (*.pipe.json)
        └── .synapse/
            ├── data/        ← NDJSON event stores
            └── checkpoints/ ← named snapshots
```

Each workspace directory is structurally identical to a local `synapse dev --root` workspace — the cloud layer is additive.

---

## 6. Migrate from single-root local

If you currently run `synapse dev --root ./my-workspace`, the legacy `/v1/*` paths continue to work when Synapse is started with a default workspace configured. To migrate to multi-tenant:

### Step 1 — Register the workspace in the platform catalog

Create the workspace first, because you need its generated `workspace_id` to know
where to unpack your data.

```bash
# On the Render shell:
synapse platform init --data-root /data           # if not yet done
synapse org create my-org --data-root /data
# → {"created":true,"org_id":"org_…","name":"my-org"}

synapse workspace create my-workspace --org <org_id> --data-root /data
# → {"created":true,"workspace_id":"ws_…","name":"my-workspace","org_id":"org_…"}
```

`workspace create` scaffolds `/data/workspaces/<workspace_id>/` with default
datasources and pipes.

### Step 2 — Copy local data over the scaffolded workspace

There is no `--import` flag. A workspace is a plain directory, so copy the files
directly — this is the whole migration.

```bash
# On your machine: pack the workspace contents (not the parent directory)
tar czf workspace.tar.gz -C ./my-workspace .

# Upload to Render (use render shell or scp via SSH key)
scp workspace.tar.gz <render-ssh-host>:/tmp/

# On the Render shell: unpack over the scaffolded workspace
tar xzf /tmp/workspace.tar.gz -C /data/workspaces/<workspace_id>

# Drop the local dev token — cloud mode ignores it, so leaving it is just a stale secret
rm -f /data/workspaces/<workspace_id>/.synapse/token
```

Keep `workspace.json`, `datasources/`, `pipes/`, and `.synapse/data/*.ndjson`.
The server reloads pipe definitions on mtime change, so pipes are live without a
restart; already-loaded event data is re-read when the workspace is next opened.

### Step 3 — Mint a token

```bash
synapse token create api --workspace <workspace_id> --scope ADMIN --data-root /data
# → prints token; narrow the scope if the client only ingests or only reads
```

### Step 4 — Point your client at the deployment

Today's Python and TypeScript SDKs take a base URL and a token only — neither
has a `workspace_id` argument, and neither rewrites paths to `/v1/w/{id}/`. So
there are two honest options.

**Option A — keep the SDK unchanged (recommended for a migration window).**
Serve the migrated workspace as the default and the existing `/v1/*` calls keep
working against it:

```bash
synapse cloud serve --data-root /data --workspace <workspace_id>
```

```python
from synapse_sdk import Synapse

s = Synapse("https://synapse-xxxx.onrender.com", token="<token>")
print(s.recall("run_demo", query="risk"))   # → GET /v1/recall
```

**Option B — address workspaces explicitly.** Call the workspace-scoped paths
directly. This is the only option if one process must serve several workspaces:

```bash
curl -H "Authorization: Bearer <token>" \
  "https://synapse-xxxx.onrender.com/v1/w/<workspace_id>/recall?run_id=run_demo&query=risk"
```

Multi-workspace support in the SDKs is not shipped. Until it is, Option B means
constructing URLs yourself.

---

## 7. Local Docker smoke test

```bash
# Build
docker build -t synapse:local .

# Bootstrap the catalog on the host before first run
mkdir -p tmp-data
./zig-out/bin/synapse platform init --data-root ./tmp-data   # prints admin_token

# Run. The image binds 0.0.0.0 and sets SYNAPSE_REQUIRE_AUTH=1; cloud serve
# refuses to start on a non-loopback address without it, so there is no
# "auth off" container mode. Do not try to override it to 0 — the process exits.
docker run --rm -p 8787:8787 \
  -e SYNAPSE_DATA_ROOT=/data \
  -v "$(pwd)/tmp-data:/data" \
  synapse:local

# Probe — cloud mode reports mode:cloud so you can tell it apart from `synapse dev`
curl http://localhost:8787/health
# {"ok":true,"product":"synapse","version":"0.1.0","mode":"cloud"}

curl http://localhost:8787/ready
# {"ready":true,"workspaces":0}

# Control plane requires the admin token printed by `platform init`
curl -H "Authorization: Bearer <admin_token>" http://localhost:8787/v1/platform/orgs
```

If you want an unauthenticated server for local poking, use single-root dev mode
instead — it binds loopback by default:

```bash
synapse dev --root examples/harness --port 8787
```

---

## 8. Security model

**Two credential kinds.** The platform `admin_token` (prefix `sk.`) lives in
`platform.json` and is the only credential accepted on `/v1/platform/*`.
Workspace tokens (prefix `p.`) are bound to exactly one `workspace_id` and one
scope. Tokens are stored as-is in `platform.json`, so that file is a secret:
keep it on the persistent disk, never in the image or in git.

**401 vs 403 is a real distinction, not a coin flip:**

| Status | Meaning |
|---|---|
| `401 unauthorized` | No token presented, or the token is unknown to the platform catalog. |
| `403 forbidden` | The token is genuine but not allowed here — bound to a different workspace, or lacking the scope this verb needs (e.g. a `PIPES:READ` token calling `POST /v1/events/...`). |
| `404 not_found` | The org, workspace, run, or route does not exist — including a workspace that exists but is not owned by the `{org_id}` in the path. |

Distinguishing them matters operationally: `401` means "fix your credential
plumbing", `403` means "the credential works but was minted for something else".

**Scope matrix.** `ADMIN` implies everything. `PIPES:READ` also satisfies
`QUERY:READ`. Otherwise a token needs the exact scope for the verb:
`EVENTS:WRITE` for ingest, `REMEMBER:WRITE` for remember/dispute,
`QUERY:READ` for datasource reads, `ADMIN` for checkpoint/reload/MCP.

**Local dev tokens are loopback-only.** `synapse init` writes a random
per-workspace token to `.synapse/token` for single-root dev mode. That file is
deliberately *not* consulted in cloud mode — `/v1/w/{id}/*` authorizes strictly
against the platform catalog, so a leaked dev token cannot reach a cloud
workspace. Cloud-scaffolded workspaces get no local token at all. Dev mode also
leaves auth off unless `SYNAPSE_REQUIRE_AUTH=1`, which is safe only because it
binds `127.0.0.1`; `cloud serve` refuses to bind any non-loopback address
without auth enabled.

**Not implemented, so do not assume it:** token revocation and rotation (delete
the entry in `platform.json` and restart to revoke), token expiry, request
signing, audit export, and TLS termination (terminate at Render or your load
balancer — Synapse speaks plain HTTP).

`scripts/e2e_cloud.sh` asserts the above end-to-end: no-token → 401, unknown
token → 401, wrong-workspace token → 403, out-of-scope token → 403, cross-org
mint → 404, and cross-workspace data isolation.

---

## 9. Storage seams (today → later)

Synapse uses pluggable backends behind trait-like interfaces in Zig:

| Layer | Today (Phase C) | Later |
|---|---|---|
| **MetaStore** (orgs/workspaces/tokens) | `platform.json` on local FS | Postgres (same interface) |
| **EventStore** (NDJSON event logs) | `workspaces/{id}/.synapse/data/*.ndjson` | S3 / Cloudflare R2 |
| **BlobStore** (checkpoints) | `workspaces/{id}/.synapse/checkpoints/` | S3 / R2 |

No live Postgres or object store is required in Phase C. The seams are documented here so the swap path is clear when horizontal scale or multi-region durability is needed.

> **Phase D target:** replace `MetaStore` with a Postgres impl; swap `EventStore` for R2 streaming. The HTTP API and SDK contracts do not change.
