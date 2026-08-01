# Tinybird → Synapse parity

Synapse is **Tinybird-shaped for AI harnesses**: same DX loop (Datasource → Pipe → Endpoint), different materialization (agent graph, not ClickHouse SQL).

| Tinybird | Synapse (local Zig) | Status |
|---|---|---|
| Workspace | `workspace.json` + `.synapse/` | Shipped |
| Data Sources | `datasources/*.json` + NDJSON tables | Shipped + schema validate |
| Events API | `POST /v1/events/{ds}` | Shipped |
| File ingest | `synapse ingest` | Shipped |
| Kafka / cloud connections | — | Roadmap (cloud) |
| Pipes (SQL nodes) | Pipes (filter / aggregate / materialize_graph / project / copy / sink) | Shipped (graph IR, not SQL) |
| TYPE ENDPOINT | `"type": "endpoint"` + HTTP/MCP | Shipped |
| TYPE MATERIALIZED | `"type": "materialized"` → target datasource on ingest | Shipped |
| TYPE COPY | `"type": "copy"` → target datasource on demand | Shipped |
| TYPE SINK | `"type": "sink"` → file export | Shipped |
| Query parameters `{{…}}` | `{{param}}` in filter where | Shipped |
| Response formats `.json/.csv/.ndjson` | Path suffix or `?format=` | Shipped |
| Query API (ad-hoc SQL) | `POST /v1/query` JSON filters (no SQL engine) | Shipped |
| Tokens (static scopes) | `.synapse/tokens.json` + `synapse token` | Shipped |
| JWTs / rate limits | — | Roadmap |
| Branches / deployments | — | Roadmap (`synapse deploy`) |
| Service data sources | `synapse_ops_log` | Shipped |
| CLI `tb build` | `synapse build` | Shipped |
| CLI `tb endpoint` | `synapse endpoint` | Shipped |
| CLI workspace / token | `synapse workspace` / `synapse token` | Shipped |
| Playgrounds / UI | — | Roadmap |
| ClickHouse interface | — | Out of scope |
| MCP | `POST /v1/mcp` | Shipped |
| Python / TS SDKs | Python shipped; TS roadmap | Partial |

## Intentional differences

1. **Primary materialization** is World/Work/Mind graph, not columnar tables.
2. **No embedded SQL** — pipes are typed IR for agent jobs (recall, plan, route, …).
3. **Local-first** — Tinybird Local analog is `synapse dev`; Cloud is roadmap.
