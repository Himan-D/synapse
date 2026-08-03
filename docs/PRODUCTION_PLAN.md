# Synapse Production Plan

**Product:** Synapse — Tinybird for AI harnesses  
**Owner:** Product + Platform  
**Horizon:** Local-first GA → Cloud beta  
**Version target:** `0.1.x` (local GA foundation)

---

## 1. Product verdict

Synapse wins when a harness builder can **instrument once, declare pipes as code, and call five agent verbs mid-run** without standing up ClickHouse + Neo4j + a memory product.

Local-first GA is not “feature complete vs Tinybird Cloud.” It is: **correct, bounded, observable, and safe enough that a serious harness can depend on it in production deploys of *their* app** (sidecar / localhost / private network).

---

## 2. Personas & JTBD

| Persona | Job | Success looks like |
|---|---|---|
| Harness builder | Ship memory + plan + metrics without infra theater | `synapse init` → ingest → `recall/plan/route` in <1 day |
| Agent runtime | Call verbs under token budget mid-run | p95 verb latency local < 50ms on demo workspace |
| Platform / security | Audit what agents believed and did | Scoped tokens, ops log, checkpoints, diffs |
| Future cloud buyer | Host multi-tenant without rewrite | Same pipes/SDK; cloud is deploy target, not new API |

---

## 3. North-star metrics (local GA)

| Metric | Target | How measured |
|---|---|---|
| Time-to-first-verb | < 30 min on clean machine | Docs + e2e script |
| Verb correctness | 100% of workspace `synapse test` green | CI |
| Ingest durability | No silent drop under normal load | NDJSON persist + reload |
| Abuse bounds | Body / query limits enforced | Unit + e2e |
| Auth completeness | Every non-public route has a scope | Auth matrix tests |
| Operability | Every request has id + structured access log | Log line contract |
| Clean shutdown | SIGINT drains current request, exits 0 | Manual + e2e kill |

Cloud metrics (later): multi-tenant isolation, ingest QPS, pipe freshness SLO.

---

## 4. Scope

### In scope for local GA (this plan)

1. **Runtime hardening** — bind host, body caps, query clamps, path safety  
2. **Observability** — request IDs, structured access logs, `/health` version+ready  
3. **Security** — scoped auth matrix tests, token query param, unsafe-name rejection  
4. **Correctness** — checkpoint/diff/dispute coverage in unit + e2e  
5. **Contract** — single version constant, OpenAPI for HTTP surface  
6. **Docs** — this plan + openapi + architecture sync  

### Explicitly out of scope (next phases)

- Kafka / ClickHouse / SQL pipes  
- JWT / OAuth / rate-limit service mesh  
- Horizontal scale / HA quorum  
- Full Temporal feature parity (timers calendar, multi-worker, exactly-once fanout)  

### Shipped since Phase B

- Durable workflows (Temporal/Inngest-shaped): `workflows/*.workflow.json`, sleep / wait_event / signal / retry / tick — see `docs/WORKFLOWS.md`  
- Multi-tenant cloud control plane — moved out of "out of scope" and shipped as Phase C beta (see below)  

---

## 5. Phased roadmap

### Phase A — Production foundation (now)

**Goal:** A single-process Synapse is safe to run beside a harness in staging/prod.

| Workstream | Deliverable | Exit criteria |
|---|---|---|
| A1 Limits | Max body 16 MiB; query limit ≤ 10k | Oversize → 413; clamp unit-tested |
| A2 Bind & config | `--host` / `SYNAPSE_HOST`; default loopback | `0.0.0.0` works for Docker |
| A3 Shutdown | SIGINT/SIGTERM unblocks accept | Process exits after in-flight request |
| A4 Request identity | `X-Request-Id` in/out + JSON access log | One log line per request |
| A5 Auth rigor | Scope matrix + Bearer/`token=` | Unit tests for all route classes |
| A6 Path safety | Checkpoint/datasource name grammar | `../` rejected |
| A7 Contract | `version.zig` + OpenAPI + health payload | Versions align on `0.1.0` |
| A8 Verification | Extended e2e (diff, checkpoint, auth) | `zig build test` + `scripts/e2e.sh` green |

### Phase B — Harness-grade reliability (next)

- [x] Schema enforce on ingest (reject missing `required` when declared)
- [x] Pipe reload file watch with mtime debounce (on accept loop)
- [x] Belief decay with ISO-8601 `valid_from`/`ts` aging
- [x] Webhook sink: best-effort HTTP POST for `http://` + durable outbox
- [x] Rate limit token bucket per token (`SYNAPSE_RATE_LIMIT`)
- [x] Ready vs live probes (`/health` live, `/ready` pipes loaded)
- [x] MCP Content-Length framing (+ NDJSON fallback); numeric arg coercion
- [ ] Webhook retry/backoff drain worker (outbox rows record `delivered`)
- [ ] HTTPS webhook delivery (TLS bundle)  

### Phase C — Platform / cloud beta

**Status: beta shipped.** Multi-tenant serving, the control plane, and the cloud
CLI are implemented and verified by `scripts/e2e_cloud.sh` in CI. Beta means the
HTTP contract is stable and isolation is tested, but it has far less production
mileage than local single-root mode, and the operational gaps listed below are
real. Local single-root remains the recommended path for production use.

#### Shipped

- [x] `Dockerfile` — Zig 0.16 multi-stage build; `synapse cloud serve`; binds `0.0.0.0:$PORT`; data at `/data`; `EXPOSE 8787`
- [x] `render.yaml` — Render Blueprint: Web Service + persistent disk `/data`; `SYNAPSE_REQUIRE_AUTH=1`; optional `SYNAPSE_RATE_LIMIT`
- [x] `docs/CLOUD.md` — Deploy guide: Render Blueprint, URL map, bootstrap, migration from single-root, security model, storage seams
- [x] `docs/openapi.yaml` — Control-plane routes + `/v1/w/{workspace_id}/*` workspace paths documented; scope enum matches `auth.zig`
- [x] URL contract locked: `/v1/*` (legacy default workspace), `/v1/w/{workspace_id}/*` (multi), `/v1/platform/*` (control plane)
- [x] `platform.zig` — org/workspace/token catalog in `platform.json`; CSPRNG ids and tokens; unknown scopes rejected at mint
- [x] `workspace_hub.zig` — lazy multi-root workspace loading; platform-store-only auth with 401/403 separation
- [x] HTTP routing — `/v1/w/{id}/*` prefix stripping + workspace resolver; nested canonical control-plane routes with org→workspace ownership checks (`404` on mismatch); flat aliases retained
- [x] Legacy `/v1/*` default workspace via `--workspace` flag or `SYNAPSE_WORKSPACE` (no silent fallback — `404` when unset)
- [x] `platform.json` mtime watch — CLI-created orgs/workspaces/tokens are served without a restart; torn writes keep the previous catalog
- [x] CLI: `synapse platform init`, `org create`, `workspace create`, `token create`, `cloud serve`
- [x] Isolation + auth-matrix e2e (`scripts/e2e_cloud.sh`): cross-workspace data isolation, no-token 401, unknown token 401, wrong-workspace 403, out-of-scope 403, cross-org mint 404, non-loopback without auth refuses to bind

#### Open in Phase C

- [ ] Token revocation / rotation as a first-class operation (today: edit `platform.json`, restart)
- [ ] Token expiry (`expires_at`) and `GET /v1/platform/.../tokens` listing over HTTP
- [ ] Multi-scope tokens — a token carries exactly one scope today, so combined ingest+read clients need `ADMIN`
- [ ] Atomic `platform.json` writes (write-temp + rename) — currently a plain overwrite
- [ ] Workspace delete / archive
- [ ] Multi-workspace support in the Python + TypeScript SDKs (they take `base_url` + `token` only; `/v1/w/{id}/*` must be constructed by hand)
- [ ] Webhook retry/backoff drain worker (Phase B carry-over)
- [ ] HTTPS webhook delivery (Phase B carry-over)

#### Explicitly out of scope (Phase D+)

- Stripe billing, SSO, multi-region HA, Kafka/ClickHouse  
- Postgres MetaStore swap, S3/R2 EventStore swap (seams documented in CLOUD.md §8)

### Phase D — Category expansion

- SQL/analytics pipes (optional ClickHouse backend)  
- Streaming ingest (Kafka/Redpanda)  
- Visual pipe editor beyond static UI  
- Enterprise SSO / audit export  

---

## 6. User stories (Phase A)

### US-A1: Bounded ingest
**As a** platform owner  
**I want** request bodies and query windows capped  
**So that** a buggy agent cannot OOM the sidecar  

**AC:**
- [x] Body > 16 MiB → HTTP 413 JSON error  
- [x] `limit` > 10000 clamped to 10000  
- [x] Documented in OpenAPI  

### US-A2: Operable process
**As an** operator  
**I want** versioned health, request IDs, and clean SIGTERM  
**So that** I can debug and roll without orphan listeners  

**AC:**
- [x] `GET /health` → `{ok, product, version}` (liveness); readiness is a separate `GET /ready` → `{ready, pipes}`. Cloud mode adds `"mode":"cloud"` to `/health` and reports `{ready, workspaces}`.  
- [x] Response includes `X-Request-Id`  
- [x] Access log JSON: `ts,request_id,method,path,status,duration_ms`  
- [x] SIGINT stops accept loop after current request  

### US-A3: Safe auth
**As a** security-minded builder  
**I want** scoped tokens that actually gate verbs  
**So that** a read token cannot ingest or checkpoint  

**AC:**
- [x] `PIPES:READ` can recall/plan; cannot POST events  
- [x] `EVENTS:WRITE` can ingest; cannot checkpoint  
- [x] Admin token can do all  
- [x] `token=` query param works when Bearer absent  

### US-A4: Checkpoint integrity
**As a** harness builder  
**I want** named checkpoints without path traversal  
**So that** agents cannot write outside `.synapse/checkpoints`  

**AC:**
- [x] Names must match `[A-Za-z0-9_.-]{1,64}`  
- [x] Diff/checkpoint e2e passes  

---

## 7. Engineering principles (MIT CS bar)

1. **Invariants over vibes** — name grammar, limit clamps, scope matrix are total functions with tests.  
2. **One source of truth** — `src/core/version.zig` feeds health, MCP, docs.  
3. **Fail closed on safety** — invalid names / oversize bodies / missing auth when required → explicit errors, never partial write.  
4. **Observable by default** — every HTTP transaction emits a structured line; correlation via request id.  
5. **Local-first honesty** — do not pretend cloud features exist; document Phase C clearly.  
6. **Small IR** — pipes remain declarative JSON; runtime stays a clear pipeline (ingest → store → materialize → serve).  

---

## 8. Risks & premortem

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Single-threaded accept stalls on slow client | Med | High | Body cap + future read timeouts (B) |
| Auth off by default → accidental exposure on `0.0.0.0` | Med | High | Warn when host ≠ loopback and auth disabled |
| Version skew across SDKs | High | Low | Pin to `0.1.0` this release |
| Checkpoint/diff semantics surprise users | Med | Med | OpenAPI examples + e2e |
| Cloud expectations before foundation | High | Med | This plan’s out-of-scope section |

---

## 9. Launch checklist (local GA)

- [x] `zig build test` green in CI  
- [x] `scripts/e2e.sh` covers verbs + checkpoint + auth  
- [x] `scripts/e2e_cloud.sh` covers multi-tenant isolation + auth matrix  
- [x] OpenAPI published under `docs/openapi.yaml`  
- [x] README links production plan + env vars  
- [x] Default bind loopback; non-loopback warns without auth (dev) / refuses to bind (cloud)  
- [x] LICENSE + CONTRIBUTING + SECURITY current  
- [x] Example harness demos all five verbs (`./scripts/demo.sh`)  

---

## 10. Decision log

| Decision | Choice | Why |
|---|---|---|
| Default bind | `127.0.0.1` | Safe local default |
| Body limit | 16 MiB | Fits NDJSON batches; prevents OOM |
| Query max limit | 10_000 | Analytics-ish without unbounded scans |
| Auth default | Off | DX for local; opt-in `SYNAPSE_REQUIRE_AUTH=1` |
| Version | `0.1.0` | Semver honesty until cloud APIs freeze |
| Shutdown | Listen-socket shutdown on signal | Zig accept cancellation mechanism |

---

## 11. Implementation map (Phase A → code)

| ID | Module / file |
|---|---|
| A1 | `src/server/http.zig`, `src/core/query.zig` |
| A2 | `src/server/http.zig`, `src/cli/commands.zig` |
| A3 | `src/server/http.zig` |
| A4 | `src/server/http.zig` |
| A5 | `src/core/auth.zig` |
| A6 | `src/core/safe_name.zig`, `diff.zig`, `http.zig` |
| A7 | `src/core/version.zig`, `docs/openapi.yaml`, SDKs |
| A8 | `scripts/e2e.sh`, unit tests |

Phase A is complete when the checklist in §9 is checked and CI is green.
