# Synapse platform surface (local-first)

## Runtime

```
SDK / UI / MCP  →  HTTP CLI  →  Datasources → Pipes → World/Work/Mind → Endpoints
```

## Verbs

| Verb | Path |
|---|---|
| ingest | `POST /v1/events/{ds}` |
| remember | `POST /v1/remember` |
| recall | `GET /v1/recall` |
| plan | `GET /v1/plan` |
| route | `GET /v1/route` |
| impact | `GET /v1/impact` |
| metrics | `GET /v1/metrics/tool_failure_rate` |
| dispute | `GET/POST /v1/dispute` |
| embed | `GET /v1/embed` |
| consolidate | `GET /v1/consolidate` |
| diff | `GET /v1/diff` |
| graph | `GET /v1/graph` |
| query | `POST /v1/query` |
| checkpoint | `POST /v1/checkpoint` |
| workspace | `GET /v1/workspace` |
| endpoints | `GET /v1/endpoints` |
| playground | `GET /` |

## CLI

`init` · `build` · `workspace` · `endpoint` · `token` · `branch create` · `checkpoint` · `graph` · `deploy` · `dev` · `ingest` · `remember` · `pipe run` · `test`

## SDKs

- Python: `sdk/python` — client, `pipes.define_pipe`, `instrument.tool_call`
- TypeScript: `sdk/typescript` — `Synapse` client

## Auth

`SYNAPSE_REQUIRE_AUTH=1` enforces Bearer tokens with scopes: `ADMIN`, `PIPES:READ`, `EVENTS:WRITE`, `REMEMBER:WRITE`, `QUERY:READ`.

## Still roadmap (cloud)

Hosted multi-tenant · Kafka · JWT rate limits · SQL pipes · columnar object store.
