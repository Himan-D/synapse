# Synapse — Product Spec (Full)

**Tagline:** Tinybird for AI harnesses.  
**One-liner:** Ingest harness events, materialize a living agent graph, and publish real-time APIs agents call mid-run — memory, plans, tools, metrics, and context as one substrate.

---

## 1. What this product is

Synapse is a **local-first (and later cloud) real-time data platform purpose-built for AI agent harnesses**.

It borrows Tinybird’s developer model:

```
Datasource  →  Pipe  →  Endpoint / MCP tool
```

…but the *primary* materialization target is not a SQL table — it is a typed, temporal, uncertain **agent graph** with three layers:

| Layer | What it holds | Why agents need it |
|---|---|---|
| **World** | Files, services, tools, docs, models, deps | Impact analysis, grounded retrieval |
| **Work** | Goals, tasks, tool ops, plans, errors, runs | Orchestration, blast radius, planning |
| **Mind** | Claims, episodes, beliefs, contradictions | Memory that doesn’t silently rot |

**Positioning**

| Product | Job |
|---|---|
| NetworkX | Compute on graphs |
| Neo4j / Memgraph | Store graphs |
| Tinybird | Turn event streams into analytics APIs |
| LangSmith / Helicone | Observe LLM traces |
| Mem0 / Zep / Graphiti | Agent memory layers |
| **Synapse** | **Run agents on graphs** — ingest + memory + planning + metrics + context packing as one Tinybird-class DX |

Synapse is not “another RAG DB.” It is the **operating plane** between your harness and your model: what happened, what we believe, what to load next, what to do next, and whether it worked.

---

## 2. Problem

Agent harnesses today bolt together:

- logs / traces (observability)
- vector stores (retrieval)
- ad-hoc JSON files (memory)
- hand-written DAGs (planning)
- SQL warehouses (metrics, delayed)

That split causes:

1. **Context amnesia** — models re-ask solved questions; tokens wasted on the wrong chunks  
2. **No write policy** — everything or nothing is stored; nothing learns *what to remember*  
3. **Opaque failures** — tool error rates and blast radius aren’t queryable mid-run  
4. **Planning fiction** — multi-agent “graphs” are slides, not executable typed state  
5. **DX cliff** — standing up ClickHouse + Neo4j + embeddings for a side project is absurd  

Agents need the Tinybird loop: **ship a pipe → get an API** — but for *agent jobs*, not pageviews.

---

## 3. Jobs to be done

### For harness builders
1. Instrument once (NDJSON / SDK) and get durable, queryable history  
2. Declare transforms as code (pipes) and publish endpoints without infra theater  
3. Give agents five verbs that actually work: **remember, recall, plan, impact, route**  
4. Measure reliability (failure rates, latency, cost) with the same substrate  

### For agents (runtime consumers)
1. `recall` — “what should I load into context under this token budget?”  
2. `remember` — “store this claim/episode with confidence + evidence”  
3. `plan` — “given goal + tool catalog, produce a task DAG”  
4. `impact` — “if this node fails/changes, what else breaks?”  
5. `route` — “which skill/agent/tool should handle this?”  
6. `metrics` — “how often does tool X fail in this run / workspace?”  

### For platform teams
1. Audit trails for regulated domains (trading, health, legal)  
2. Multi-tenant workspaces, tokens, branchable event logs  
3. Hosted Synapse Cloud (ingest + pipes + MCP) without rewriting harnesses  

---

## 4. Product surfaces

### 4.1 Workspace (project unit)
A directory (or cloud workspace) containing:

```
workspace.json
datasources/*.json
pipes/*.pipe.json
.synapse/token
.synapse/data/*.ndjson
```

Tinybird analog: workspace. Synapse adds graph materialization config and agent verb bindings.

### 4.2 Datasources
Typed append-only event streams. Built-ins:

- `harness_events` — universal envelope  
- `tool_calls` — tool invocations  
- `llm_spans` — model calls / tokens  
- `memory_writes` — explicit remembers  
- `plan_steps` — planner / executor steps  
- `beliefs` — confidence-bearing mind updates  

Envelope:

```json
{
  "ts": "ISO-8601",
  "run_id": "string",
  "agent_id": "string",
  "type": "tool_call|llm_span|memory_write|plan_step|error|belief",
  "payload": {}
}
```

### 4.3 Pipes
Declarative transform graphs (JSON today; SDK DSLs later). Node types:

| Node | Role |
|---|---|
| `filter` | Select events (`{{params}}`) |
| `aggregate` | Tinybird-style counts / rates / groups |
| `materialize_graph` | Events → World/Work/Mind |
| `project` | `context_pack` · `blast_radius` · `plan` · `route` · `passthrough` |
| `believe` | Upsert Mind claims with confidence / evidence / decay |
| `contradict` | Detect conflicting claims; emit dispute edges |
| `embed` | Attach / query vector neighbors (hybrid with structure) |
| `sink` | Emit to webhook / file / downstream datasource |

### 4.4 Endpoints & MCP
Every pipe can publish:

- HTTP: `GET/POST /v1/pipes/{name}` and friendly aliases (`/v1/recall`, `/v1/plan`, …)  
- MCP tools: `synapse.*` for agent runtimes  

### 4.5 CLI
`synapse init | dev | ingest | pipe run | test | workspace | token`

### 4.6 SDKs
- **Zig core** (this repo) — runtime  
- **Python SDK** — harness instrumentation + typed clients  
- **TypeScript SDK** (roadmap) — web / Node harnesses  

### 4.7 Cloud (roadmap)
Managed ingest, storage, branching, multi-tenant tokens, hosted MCP — same workspace files, `synapse deploy`.

---

## 5. Core agent verbs (full product)

| Verb | Meaning | Output |
|---|---|---|
| **ingest / remember** | Append events; optional Mind upsert with confidence | `{ ingested }` / claim node |
| **recall** | Token-budgeted context pack over Mind+World (+Work) | `{ nodes, edges, summary, citations, tokens_used }` |
| **plan** | Goal → task/tool DAG using Work layer + tool catalog | `{ goal, steps[], edges[], missing[] }` |
| **impact** | Blast radius from a node / error | `{ seed, impacted[] }` |
| **route** | Pick best tool/skill/agent for a query | `{ choice, candidates[], scores[] }` |
| **metrics** | Aggregates over tool/LLM/run dimensions | `{ groups[] }` |
| **dispute** | Mark contradiction between claims | `{ edge }` |
| **diff** | What changed since checkpoint / run | `{ added, removed, updated }` |

---

## 6. Graph physics (Mind)

Every Mind edge/node carries:

```
confidence ∈ [0,1]
evidence[]          # event ids / tool outputs
valid_from / valid_to
decay_half_life     # optional
contradicts[]       # peer claim ids
```

Ops:

- `believe(text, confidence, evidence)`  
- `dispute(a, b, reason)`  
- `consolidate()` — merge near-duplicate claims (roadmap)  
- decay over wall-clock so stale “facts” lose rank in `recall`

This is how Synapse differs from dumb append-only memory: **beliefs have physics**.

---

## 7. Planning model (Work)

Tools/skills are operators:

```
Tool { name, requires[], provides[], cost{tokens, latency_ms} }
```

`plan(goal, start_state)` searches a typed Work graph (STRIPS-ish / topo expand):

1. Match missing `provides` against tool catalog  
2. Emit task nodes + `enables` / `requires` edges  
3. Return ordered steps + unresolved gaps  

Not a chatbot pretending to plan — a **graph search** over your actual tool surface.

---

## 8. Context packing (the money feature)

`recall` is personalized PageRank-ish packing:

1. Materialize relevant layers for `run_id` / query  
2. Score: recency × kind boost × query match × belief confidence × (1 − decay)  
3. Greedy pack under `budget_tokens`  
4. Return nodes + edges + citations (never silent drops without citations)

Success metric: **same agent, fewer tokens, fewer repeated mistakes** vs flat RAG.

---

## 9. Observability (Tinybird lane)

Same events power analytics pipes:

- tool failure rate by tool / agent / hour  
- LLM token burn by run  
- error cascades (impact join)  
- harness SLO dashboards (cloud UI roadmap)

One write path → memory **and** metrics. No dual instrumentation.

---

## 10. Architecture (logical)

```
┌─────────────┐   ┌──────────────┐   ┌─────────────┐
│ Python SDK  │   │ TS / harness │   │ MCP clients │
└──────┬──────┘   └──────┬───────┘   └──────┬──────┘
       └─────────────────┼──────────────────┘
                         ▼
              ┌─────────────────────┐
              │   Synapse Runtime   │
              │  HTTP · MCP · CLI   │
              └──────────┬──────────┘
                         ▼
         Datasources (append log) → Pipe engine
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
       World           Work           Mind
          │              │              │
          └──────────────┼──────────────┘
                         ▼
              Endpoints (recall/plan/…)
```

**Persistence:** append-only NDJSON (local); object store + columnar (cloud).  
**Indexes:** run_id, type, agent_id; optional ANN for embed nodes.  
**Auth:** workspace bearer tokens (local file / cloud IAM).

---

## 11. Implementation status

| Capability | Status |
|---|---|
| Workspace · datasources · NDJSON ingest | **Shipped** |
| Pipe IR: filter / aggregate / materialize / project / copy / sink | **Shipped** |
| Pipe kinds: endpoint · materialized · copy · sink | **Shipped** |
| recall · metrics · impact · plan · route · remember · dispute | **Shipped** |
| Response formats json / ndjson / csv | **Shipped** |
| Query API (`POST /v1/query`) | **Shipped** |
| Service datasource `synapse_ops_log` | **Shipped** |
| `synapse build` / `workspace` / `endpoint` / `token` | **Shipped** |
| HTTP + MCP (full verb surface) | **Shipped** |
| Dynamic pipe directory scan | **Shipped** |
| Bearer auth (`SYNAPSE_REQUIRE_AUTH=1`) | **Shipped** |
| Python SDK (`sdk/python`) | **Shipped** |
| Confidence-weighted recall | **Shipped** |
| Tinybird parity matrix | [docs/tinybird-parity.md](docs/tinybird-parity.md) |
| Mind decay × confidence recall | **Shipped** |
| consolidate · write dispute · diff · checkpoint | **Shipped** |
| Local embed hybrid recall | **Shipped** (hash embedder) |
| Scoped token auth | **Shipped** |
| Graph inspect API · playground UI | **Shipped** |
| Local branches · `synapse deploy` validate | **Shipped** (local stubs) |
| TypeScript SDK + Python pipe DSL / instrument | **Shipped** |
| `tools.json` catalog for plan/route | **Shipped** |
| Aggregate ops count / rate / sum · LLM token metrics | **Shipped** |
| Webhook sink outbox · MCP stdio CLI | **Shipped** |
| Datasource schema checks · GitHub CI · LICENSE | **Shipped** |
| Cloud multi-tenant · SQL pipes · JWT · Kafka | Roadmap |
| Hypergraphs · CRDT merge · GNN | Research |

---

## 12. Roadmap

### Now (this build)
- Full verb surface: plan, route, remember/believe, dispute  
- Stronger Mind physics + decay ranking in recall  
- Python SDK + richer example harness  
- Complete product documentation (this file)

### Next
- TypeScript SDK  
- Embeddings provider plugins (local / OpenAI)  
- Pipe SDK (Python define_pipe)  
- Workspace branches / time-travel diff  
- Web UI: explore graph + pipe playground  

### Later
- Synapse Cloud (hosted ingest + MCP)  
- SQL pipe dialect (opt-in Tinybird parity)  
- Multi-agent CRDT merge policies  
- Regulated audit packs (trading / health)

---

## 13. Non-goals

- Replacing your primary OLTP database  
- Being a general graph DB query language (Cypher clone) on day one  
- Training foundation models  
- Auto-prompting magic without an instrumented harness  

---

## 14. Success metrics (product)

1. **Time-to-first-endpoint** < 2 minutes from clone  
2. **Recall quality** — agent with Synapse recall beats flat RAG on fixed eval (task success, repeats, tokens)  
3. **Metrics fidelity** — tool failure rates match hand labels on fixtures  
4. **Plan usefulness** — `plan` returns executable steps covering goal provides  
5. **DX** — pipes-as-code reviewable in PRs; `synapse test` in CI  

---

## 15. Why Zig

- Single static binary for `synapse dev` (Tinybird Local energy)  
- Predictable latency for ingest + packing on the hot path  
- Embeddable runtime later (harness links Synapse instead of HTTP)  
- Python/TS remain the *authoring* languages; Zig is the *engine*

---

## 16. Summary

**Synapse is the real-time control plane for AI harnesses:**  
events in → graph + metrics out → agents call `recall` / `plan` / `impact` / `route` / `remember` like tools.

Tinybird taught developers to ship data products as APIs.  
Synapse teaches harnesses to ship **agent cognition** the same way.
