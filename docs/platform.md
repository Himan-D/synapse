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

Single-workspace: `init` · `build` · `workspace` · `endpoint` · `token` · `branch create` · `checkpoint` · `graph` · `workflow` · `deploy` · `dev` · `ingest` · `remember` · `pipe run` · `test`

Multi-workspace: `platform init` · `org create` · `workspace create` · `token create --workspace` · `cloud serve`

## SDKs

- Python: `sdk/python` — client, `pipes.define_pipe`, `instrument.tool_call`
- TypeScript: `sdk/typescript` — `Synapse` client

Both take `base_url` + `token`. Neither knows about workspace prefixes yet, so
multi-workspace callers build `/v1/w/{id}/...` URLs themselves.

## Auth

`SYNAPSE_REQUIRE_AUTH=1` enforces Bearer tokens (or `?token=`) with scopes: `ADMIN`, `PIPES:READ`, `EVENTS:WRITE`, `REMEMBER:WRITE`, `QUERY:READ`. Those five are the complete set — anything else is rejected when the token is minted.

`401` = no token or unknown token. `403` = real token, wrong workspace or missing scope. See [CLOUD.md §8](CLOUD.md#8-security-model).

## Multi-tenant (Phase C beta)

Shipped and tested by `scripts/e2e_cloud.sh`: orgs → workspaces → scoped tokens in `platform.json`, `/v1/w/{workspace_id}/*` routing, admin-only `/v1/platform/*` control plane, optional default workspace for bare `/v1/*`. See [CLOUD.md](CLOUD.md).

## Still roadmap

Token revocation/rotation/expiry · multi-scope tokens · Kafka · JWT · SQL pipes · columnar object store.
