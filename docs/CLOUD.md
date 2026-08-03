# Synapse Cloud — Deploy Guide

> **Phase C** — multi-workspace cloud deploy on Render.  
> See [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md) for the full roadmap.

---

## Contents

1. [Architecture overview](#1-architecture-overview)
2. [URL routing map](#2-url-routing-map)
3. [Deploy to Render (Blueprint)](#3-deploy-to-render-blueprint)
4. [Environment variables reference](#4-environment-variables-reference)
5. [First-run bootstrap (platform init)](#5-first-run-bootstrap-platform-init)
6. [Migrate from single-root local](#6-migrate-from-single-root-local)
7. [Local Docker smoke test](#7-local-docker-smoke-test)
8. [Storage seams (today → later)](#8-storage-seams-today--later)

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
| **Legacy / single-root** | `/v1/*` | workspace or admin | Default workspace (compat shim — same behavior as `synapse dev`) |
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

# Control plane
GET  /v1/platform/orgs
POST /v1/platform/orgs
GET  /v1/platform/orgs/{org_id}/workspaces
POST /v1/platform/orgs/{org_id}/workspaces
POST /v1/platform/orgs/{org_id}/workspaces/{workspace_id}/tokens
```

**Token scoping rules:**
- An **admin token** may call any path.
- A **workspace-scoped token** carries `workspace_id`; requests to `/v1/w/{id}/*` must match — mismatch → `403`.
- A workspace token used on the legacy `/v1/*` path resolves to its bound workspace.
- `SYNAPSE_REQUIRE_AUTH=1` is always set in the Docker image — `Authorization: Bearer <token>` or `?token=` required.

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

# Mint an admin token for this workspace
synapse token create admin --workspace <workspace_id> --data-root /data
# → prints token (store it securely)
```

> **Note:** The `synapse platform`, `synapse org`, `synapse workspace`, and `synapse token` CLI commands are part of Phase C implementation (todo: `cli-cloud`). If they are not yet shipped, use the control-plane HTTP API directly after first deploy (see §2 URL map).

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

The platform catalog stores orgs, workspaces, and tokens in `$SYNAPSE_DATA_ROOT/platform.json`. This file is created by `synapse platform init`. On a fresh Render deploy with an empty disk, Synapse will emit a warning and refuse to serve workspace routes until initialized.

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

### Step 1 — Copy local data to the Render disk

```bash
# Compress your local workspace
tar czf workspace.tar.gz ./my-workspace

# Upload to Render (use render shell or scp via SSH key)
scp workspace.tar.gz <render-ssh-host>:/data/
```

### Step 2 — Register the workspace in the platform catalog

```bash
# On the Render shell:
synapse platform init --data-root /data           # if not yet done
synapse org create my-org --data-root /data
synapse workspace create my-workspace --org <org_id> \
  --data-root /data --import /data/workspace.tar.gz
synapse token create admin --workspace <workspace_id> --data-root /data
```

### Step 3 — Update SDK / client base URL

```python
# Before (local):
s = Synapse("http://127.0.0.1:8787")

# After (cloud, workspace-scoped):
s = Synapse(
    "https://synapse-xxxx.onrender.com",
    workspace_id="<workspace_id>",
    token="<token>",
)
# SDK prefixes /v1/w/{workspace_id}/ automatically (v0.2+)
# or call /v1/w/{workspace_id}/recall etc. directly
```

### Backward-compat note

The legacy `/v1/*` path remains available as long as Synapse has a default workspace configured (via `SYNAPSE_WORKSPACE` env var or `--workspace` flag to `cloud serve`). This allows existing integrations to continue working during a migration window.

---

## 7. Local Docker smoke test

```bash
# Build
docker build -t synapse:local .

# Run (auth off for local testing only — never in production)
docker run --rm -p 8787:8787 \
  -e SYNAPSE_REQUIRE_AUTH=0 \
  -e SYNAPSE_DATA_ROOT=/data \
  -v "$(pwd)/tmp-data:/data" \
  synapse:local

# Probe
curl http://localhost:8787/health
# {"ok":true,"product":"synapse","version":"0.1.0"}

# Test with auth (production-style)
docker run --rm -p 8787:8787 \
  -e SYNAPSE_REQUIRE_AUTH=1 \
  -e SYNAPSE_DATA_ROOT=/data \
  -v "$(pwd)/tmp-data:/data" \
  synapse:local
```

---

## 8. Storage seams (today → later)

Synapse uses pluggable backends behind trait-like interfaces in Zig:

| Layer | Today (Phase C) | Later |
|---|---|---|
| **MetaStore** (orgs/workspaces/tokens) | `platform.json` on local FS | Postgres (same interface) |
| **EventStore** (NDJSON event logs) | `workspaces/{id}/.synapse/data/*.ndjson` | S3 / Cloudflare R2 |
| **BlobStore** (checkpoints) | `workspaces/{id}/.synapse/checkpoints/` | S3 / R2 |

No live Postgres or object store is required in Phase C. The seams are documented here so the swap path is clear when horizontal scale or multi-region durability is needed.

> **Phase D target:** replace `MetaStore` with a Postgres impl; swap `EventStore` for R2 streaming. The HTTP API and SDK contracts do not change.
