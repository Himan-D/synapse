# Synapse Architecture

## Runtime flow

```
AgentHarness ──NDJSON──► EventsAPI ──► Datasources (append log)
                                      │
                                      ▼
                                   Pipes
                          ┌──────────┼──────────┐
                          ▼          ▼          ▼
                       World       Work        Mind
                          │          │          │
                          └────┬─────┴────┬─────┘
                               ▼          ▼
                          MetricsViews  ContextPack
                               │          │
                               └────┬─────┘
                                    ▼
                           HTTP endpoints + MCP
```

## Event envelope

Every datasource row shares:

```json
{
  "ts": "ISO-8601",
  "run_id": "string",
  "agent_id": "string",
  "type": "tool_call|llm_span|memory_write|plan_step|error",
  "payload": { }
}
```

Built-in datasources: `harness_events`, `tool_calls`, `llm_spans`, `memory_writes`.

## Graph primitives

```
Node { id, layer: world|work|mind, kind, props_json, valid_from, valid_to }
Edge { id, src, dst, kind, confidence, evidence_json, props_json }
```

Materialization rules (MVP):

| Event type | Nodes / edges |
|---|---|
| `tool_call` | Work node `tool_op:{name}`, World node `tool:{name}`, edge `calls` |
| `memory_write` | Mind node `claim:{hash}`, edge `derived_from` run |
| `plan_step` | Work node `task:{id}`, edge `enables` / `blocks` |
| `error` | Work node `error:{id}`, edge `caused_by` tool_op |
| `llm_span` | Work node `llm:{id}` (optional World `model:{name}`) |

## Pipe IR

Pipe files are JSON (`*.pipe.json`):

```json
{
  "name": "recall_context",
  "nodes": [
    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
    { "type": "materialize_graph", "layers": ["mind", "world"] },
    { "type": "project", "op": "context_pack", "budget_tokens": 4000 }
  ],
  "endpoint": { "path": "/v1/recall", "params": ["run_id", "query"] }
}
```

Node types:

1. **filter** — select events by equality on envelope fields (`{{param}}` substitution)
2. **aggregate** — `count` / `rate` grouped by a field (Tinybird-style metrics)
3. **materialize_graph** — apply materialization rules into World/Work/Mind
4. **project** — `context_pack` | `blast_radius` | `passthrough`

## Persistence

- Append-only NDJSON under `.synapse/data/{datasource}.ndjson`
- In-memory indexes rebuilt on workspace load (run_id → event offsets)
- Graph is ephemeral materialization from filtered events (not separately persisted in MVP)

## HTTP API

| Method | Path | Body / query | Response |
|---|---|---|---|
| POST | `/v1/events/{datasource}` | NDJSON body | `{ "ingested": N }` |
| GET | `/v1/pipes/{name}?k=v` | query params | JSON result |
| POST | `/v1/mcp` | JSON-RPC | MCP result |
| GET | `/health` | — | `{ "ok": true }` |

Auth: `Authorization: Bearer <token>` when `.synapse/token` exists.

## MCP tools

| Tool | Args | Behavior |
|---|---|---|
| `synapse.ingest` | `datasource`, `events` (array) | append events |
| `synapse.recall` | `run_id`, `query?`, `budget_tokens?` | run `recall_context` |
| `synapse.metrics` | `run_id?` | run `tool_failure_rate` |

## Module layout

```
src/
  root.zig           public exports
  main.zig           CLI entry (process.Init)
  core/
    event.zig        envelope parse/validate
    store.zig        append log + indexes
    graph.zig        Node/Edge + materialize
    pipe.zig         IR + executor
    context_pack.zig token-budgeted recall
    workspace.zig    load workspace.json + pipes
  server/
    http.zig         Io.net HTTP server
    mcp.zig          JSON-RPC dispatch
  cli/
    commands.zig     init / dev / ingest / test
```

## Context pack algorithm (MVP)

1. Materialize Mind + World for `run_id`
2. Score nodes: recency + kind boost (claim > tool > file) + optional query substring match
3. Greedily pack nodes/edges until `budget_tokens` (approx `len/4`)
4. Emit JSON `{ nodes, edges, summary, citations }`
