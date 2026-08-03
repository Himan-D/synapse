# Synapse

**Tinybird for AI harnesses** — ingest agent events, declare pipes as code, publish World / Work / Mind endpoints (and MCP tools).

> NetworkX computes on graphs. Neo4j stores graphs. Synapse runs agents on graphs.

See [PRODUCT.md](PRODUCT.md), [docs/PRODUCTION_PLAN.md](docs/PRODUCTION_PLAN.md), [docs/WORKFLOWS.md](docs/WORKFLOWS.md), [docs/openapi.yaml](docs/openapi.yaml), [docs/architecture.md](docs/architecture.md), and **[docs/CLOUD.md](docs/CLOUD.md)** for Render/Docker cloud deploy.

## Requirements

- Zig 0.16+

## Quickstart (< 2 minutes)

```bash
./scripts/demo.sh
```

That single command: builds (if needed) → ingests sample events → starts the server → curls every
endpoint with labelled output → prints the playground URL → keeps the server alive until `Ctrl-C`.

```
Open playground  →  http://127.0.0.1:8787/
MCP endpoint     →  http://127.0.0.1:8787/v1/mcp
API base         →  http://127.0.0.1:8787/v1/
```

Optional port override: `./scripts/demo.sh 9000`

### Manual steps (same as the script)

```bash
zig build

# ingest sample events
./zig-out/bin/synapse ingest harness_events examples/harness/sample_events.ndjson \
  --root examples/harness --replace

# serve HTTP + MCP + playground UI
./zig-out/bin/synapse dev --root examples/harness --port 8787
# open http://127.0.0.1:8787/
```

In another terminal:

```bash
curl -s 'http://127.0.0.1:8787/health'
curl -s 'http://127.0.0.1:8787/v1/recall?run_id=run_demo&query=risk'
curl -s 'http://127.0.0.1:8787/v1/plan?goal=fix%20risk%20bug&run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/route?query=run%20tests&run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/metrics/tool_failure_rate?run_id=run_demo'
curl -s -X POST 'http://127.0.0.1:8787/v1/remember' \
  -H 'content-type: application/json' \
  -d '{"run_id":"run_demo","text":"margin risk is elevated","confidence":0.9}'
```

### CI / full e2e (includes auth, schema-reject, workflow tests)

```bash
./scripts/e2e.sh
```

## CLI

| Command | Purpose |
|---|---|
| `synapse init [dir] [name]` | Create workspace (datasources, pipes, token) |
| `synapse build --root <dir>` | Validate workspace (`tb build` analog) |
| `synapse workspace --root <dir>` | List pipes + types |
| `synapse endpoint --root <dir>` | List published endpoints |
| `synapse token show\|create [name]` | Admin / scoped tokens |
| `synapse mcp --root <dir>` | MCP over stdio (Cursor / Claude Desktop) |
| `synapse branch create <name>` | Snapshot local event data |
| `synapse workflow list\|start\|signal\|tick…` | Durable workflows (Temporal/Inngest-shaped) |
| `synapse graph --run-id <id>` | Inspect World/Work/Mind |
| `synapse deploy --root <dir>` | Local validate (cloud promote later) |
| `synapse dev --root <dir> --port <n> [--host 127.0.0.1]` | Serve HTTP + MCP + playground |
| `synapse ingest <ds> <file.ndjson> --root <dir> [--replace]` | Append (or replace) events |
| `synapse remember "<text>" --root <dir> --run-id <id>` | Write a Mind claim |
| `synapse pipe run <name> --root <dir> --run-id <id>` | Run a pipe offline |
| `synapse test --root <dir>` | Verify build + verbs + copy/sink |

## Product surface

```
Datasource  →  Pipe  →  Endpoint / MCP tool
(events)       (filter / aggregate / materialize_graph / project)
```

Default pipes:

| Pipe | Endpoint | Job |
|---|---|---|
| `recall_context` | `/v1/recall` | Token-budgeted Mind+World pack |
| `plan_goal` | `/v1/plan` | Goal → tool DAG |
| `route_query` | `/v1/route` | Query → best tool/skill |
| `tool_failure_rate` | `/v1/metrics/tool_failure_rate` | Aggregate failure rates |
| `blast_radius` | `/v1/impact` | Work/World impact |
| `find_contradictions` | `/v1/dispute` | Opposing Mind claims |

Auth is opt-in: set `SYNAPSE_REQUIRE_AUTH=1` to require `Authorization: Bearer <token>` (or `?token=`) from `.synapse/token`.  
Bind host via `--host` / `SYNAPSE_HOST` (default loopback; non-loopback without auth logs a warning).  
Optional `SYNAPSE_RATE_LIMIT=<req/s>` token-bucket per token.  
Bodies capped at 16 MiB; query `limit` clamped to 10_000. Every response includes `X-Request-Id`.  
Probes: `GET /health` (liveness) · `GET /ready` (pipes loaded). Datasource schemas enforced on ingest.

Pipe types (Tinybird-shaped): `endpoint` · `materialized` · `copy` · `sink`  
Formats: `/v1/pipes/{name}.json|.ndjson|.csv` or `?format=`  
Query API: `POST /v1/query` with `{ datasource, where, limit, offset }`

Full Tinybird mapping: [docs/tinybird-parity.md](docs/tinybird-parity.md).  
Production roadmap: [docs/PRODUCTION_PLAN.md](docs/PRODUCTION_PLAN.md).

## MCP

`POST /v1/mcp` JSON-RPC tools:

`synapse.ingest` · `synapse.remember` · `synapse.recall` · `synapse.plan` · `synapse.route` · `synapse.impact` · `synapse.metrics` · `synapse.dispute`

## Python SDK

```bash
cd sdk/python
pip install -e .
```

```python
from synapse_sdk import Synapse

s = Synapse("http://127.0.0.1:8787")
print(s.recall("run_demo", query="risk"))
print(s.plan("fix risk bug", run_id="run_demo"))
s.remember("run_demo", "margin risk is elevated", confidence=0.9)
```

## Cloud Deploy (Render)

```bash
# Build image locally
docker build -t synapse:local .

# One-click Render deploy: push repo → Render dashboard → New → Blueprint
# render.yaml is at the repo root; see docs/CLOUD.md for full setup guide.
```

See **[docs/CLOUD.md](docs/CLOUD.md)** for:
- Render Blueprint deploy steps
- URL map (`/v1/*` vs `/v1/w/{id}/*` vs `/v1/platform/*`)
- Migration from single-root local
- Environment variables reference

## Develop

```bash
zig build test
zig build run -- test --root examples/harness
```
