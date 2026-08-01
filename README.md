# Synapse

**Tinybird for AI harnesses** — ingest agent events, declare pipes as code, publish World / Work / Mind endpoints (and MCP tools).

> NetworkX computes on graphs. Neo4j stores graphs. Synapse runs agents on graphs.

See [PRODUCT.md](PRODUCT.md) and [docs/architecture.md](docs/architecture.md).

## Requirements

- Zig 0.16+

## Quickstart (< 2 minutes)

```bash
zig build

# use the example workspace
./zig-out/bin/synapse ingest harness_events examples/harness/sample_events.ndjson --root examples/harness --replace
./zig-out/bin/synapse test --root examples/harness

# serve HTTP + MCP
./zig-out/bin/synapse dev --root examples/harness --port 8787
```

In another terminal:

```bash
curl -s 'http://127.0.0.1:8787/health'
curl -s 'http://127.0.0.1:8787/v1/workspace'
curl -s 'http://127.0.0.1:8787/v1/recall?run_id=run_demo&query=risk'
curl -s 'http://127.0.0.1:8787/v1/plan?goal=fix%20risk%20bug&run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/route?query=run%20tests&run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/dispute?run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/metrics/tool_failure_rate?run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/impact?run_id=run_demo'
curl -s -X POST 'http://127.0.0.1:8787/v1/remember' \
  -H 'content-type: application/json' \
  -d '{"run_id":"run_demo","text":"margin risk is elevated","confidence":0.9}'
```

Or run the bundled script:

```bash
./scripts/e2e.sh
```

## CLI

| Command | Purpose |
|---|---|
| `synapse init [dir] [name]` | Create workspace (datasources, pipes, token) |
| `synapse dev --root <dir> --port <n>` | Serve HTTP + MCP |
| `synapse ingest <ds> <file.ndjson> --root <dir> [--replace]` | Append (or replace) events |
| `synapse remember "<text>" --root <dir> --run-id <id>` | Write a Mind claim |
| `synapse pipe run <name> --root <dir> --run-id <id>` | Run a pipe offline |
| `synapse test --root <dir>` | Verify recall / plan / route / metrics / blast / dispute |

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

Auth is opt-in: set `SYNAPSE_REQUIRE_AUTH=1` to require `Authorization: Bearer <token>` from `.synapse/token`.

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

## Develop

```bash
zig build test
zig build run -- test --root examples/harness
```
