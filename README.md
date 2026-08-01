# Synapse

**Tinybird for AI harnesses** — ingest agent events, declare pipes as code, publish `recall` / `metrics` / `impact` APIs (and MCP tools).

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
curl -s 'http://127.0.0.1:8787/v1/recall?run_id=run_demo&query=risk'
curl -s 'http://127.0.0.1:8787/v1/metrics/tool_failure_rate?run_id=run_demo'
curl -s 'http://127.0.0.1:8787/v1/impact?run_id=run_demo'
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
| `synapse pipe run <name> --root <dir> --run-id <id>` | Run a pipe offline |
| `synapse test --root <dir>` | Verify recall / metrics / blast |

## Tinybird-shaped model

```
Datasource  →  Pipe  →  Endpoint / MCP tool
(events)       (filter / aggregate / materialize_graph / context_pack)
```

Default pipes in every workspace:

- `recall_context` — token-budgeted Mind+World pack
- `tool_failure_rate` — Tinybird-style aggregate
- `blast_radius` — Work/World impact

## MCP

`POST /v1/mcp` JSON-RPC tools:

- `synapse.ingest`
- `synapse.recall`
- `synapse.metrics`

## Develop

```bash
zig build test
zig build run -- test --root examples/harness
```
