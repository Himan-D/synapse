# Synapse — Tinybird for AI Harnesses

## One-liner

Ingest harness events over HTTP. Declare pipes as code. Publish sub-second `recall`, `impact`, and `metrics` APIs (and MCP tools) that agents actually call.

## Thesis

**Tinybird** turns event streams into real-time APIs via Datasources → Pipes → Endpoints.  
**Synapse** does the same for AI harnesses — but the primary materialization target is a typed, temporal agent graph (**World / Work / Mind**), not only SQL aggregates.

NetworkX computes on graphs. Neo4j stores graphs. Synapse *runs agents on graphs*: memory, plans, tools, and context as one typed, event-sourced substrate with Tinybird-class developer experience.

## Who it is for

Builders of agent harnesses (CLI agents, multi-agent runtimes, trading agents, custom tool loops) who need:

1. Durable ingest of tool/LLM/memory events
2. Declarative transforms (pipes) without standing up ClickHouse
3. Token-budgeted context packs agents can call mid-run
4. Simple metrics endpoints (failure rates, blast radius)

## Product model (Tinybird mapping)

| Tinybird | Synapse |
|---|---|
| Workspace | `workspace.json` |
| Datasource | `datasources/*.json` typed event stream |
| Events API | `POST /v1/events/:datasource` (NDJSON) |
| Pipe | JSON pipe: filter / project / aggregate / materialize_graph |
| Endpoint | Published HTTP route + MCP tool |
| `tb` CLI | `synapse` CLI (`init`, `dev`, `ingest`, `test`) |
| Tokens | Local workspace token (`.synapse/token`) |

## Three graph layers

| Layer | Nodes | Edges | Agent use |
|---|---|---|---|
| **World** | files, services, tools, docs | depends_on, calls, owns | impact / retrieval |
| **Work** | goals, tasks, tool ops, plans | blocks, enables, spawns | planning / orchestration |
| **Mind** | claims, episodes, hypotheses | supports, contradicts, derived_from | memory / belief |

## MVP verbs

| Verb | Surface | Status |
|---|---|---|
| `ingest` / remember | `POST /v1/events/{ds}`, MCP `synapse.ingest` | shipped |
| `recall` | pipe `recall_context`, MCP `synapse.recall` | shipped |
| `metrics` | pipe `tool_failure_rate`, MCP `synapse.metrics` | shipped |
| `impact` | pipe `blast_radius` | shipped |
| `plan` | stub | later |
| `route` | stub | later |

## Non-goals (MVP)

- Full SQL / ClickHouse
- Hosted multi-tenant cloud
- Vector ANN (interface stub only)
- Hypergraphs, CRDT merge, GNN
- Billing / Stripe Connect
- Python/TS SDK (CLI + HTTP first)

## Success metrics

- `zig build test` green
- `synapse dev` + ingest sample events without crash
- `recall_context` returns a non-empty pack with node citations
- `tool_failure_rate` matches hand-checked fixture
- Cold start to first endpoint call under 2 minutes from README
