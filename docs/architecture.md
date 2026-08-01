# Synapse Architecture (Full Product)

See also [PRODUCT.md](../PRODUCT.md) for the product thesis and verb catalog.

## Runtime flow

```
Harness / SDK / MCP
        │
        ▼
   HTTP · CLI · MCP
        │
        ▼
 Datasources (append-only NDJSON)
        │
        ▼
     Pipe engine
   filter → materialize_graph → project/aggregate
        │
   ┌────┼────┐
   ▼    ▼    ▼
 World Work Mind  (+ Metrics views)
   │    │    │
   └────┼────┘
        ▼
 Endpoints: recall · plan · route · impact · metrics · dispute · remember
```

## Modules (Zig)

| Module | Responsibility |
|---|---|
| `core/event.zig` | Envelope parse/validate |
| `core/store.zig` | Append log + indexes + persist |
| `core/graph.zig` | World/Work/Mind materialization |
| `core/pipe.zig` | Pipe IR + executor |
| `core/context_pack.zig` | Token-budgeted recall (confidence-weighted) |
| `core/plan.zig` | Goal → tool/task DAG |
| `core/route.zig` | Query → best tool/skill |
| `core/belief.zig` | remember events + contradiction detection |
| `core/workspace.zig` | Load workspace, scan pipes, verbs |
| `server/http.zig` | HTTP API |
| `server/mcp.zig` | MCP JSON-RPC tools |
| `cli/commands.zig` | CLI |

## Pipe project ops

`context_pack` · `blast_radius` · `plan` · `route` · `contradict` · `passthrough`

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness |
| GET | `/v1/workspace` | List pipes |
| POST | `/v1/events/{ds}` | Ingest NDJSON |
| POST | `/v1/remember` | Mind claim upsert |
| GET | `/v1/recall` | Context pack |
| GET | `/v1/plan` | Plan DAG |
| GET | `/v1/route` | Tool routing |
| GET | `/v1/impact` | Blast radius |
| GET | `/v1/metrics/tool_failure_rate` | Aggregates |
| GET | `/v1/dispute` | Contradictions |
| GET | `/v1/pipes/{name}` | Run any pipe |
| POST | `/v1/mcp` | MCP tools |

Auth: set `SYNAPSE_REQUIRE_AUTH=1` to require `Authorization: Bearer <token>` from `.synapse/token`.

## MCP tools

`synapse.ingest` · `synapse.remember` · `synapse.recall` · `synapse.plan` · `synapse.route` · `synapse.impact` · `synapse.metrics` · `synapse.dispute`

## Persistence

- Local: `.synapse/data/{datasource}.ndjson`
- Graph: ephemeral materialization from filtered events
- Cloud (roadmap): object store + columnar + branchable logs

## Python SDK

`sdk/python/synapse_sdk` — thin HTTP client for all verbs.
