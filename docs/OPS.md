# Ops capture — who did what

Synapse **ops** is drop-in agent activity logging for any repo. It records events you explicitly wire in via MCP, IDE hooks, or SDK decorators — **not** silent IDE surveillance.

## Honest limits

| Captured when wired | Not captured automatically |
|---|---|
| MCP `tools/call` via `synapse ops mcp` | Every keystroke or chat message |
| Cursor/Claude hooks you configure | Built-in editor tools unless hooked |
| Python `@tool_call` / TS `wrapTool()` | File reads the agent never reports |
| Direct `POST /v1/events/harness_events` | Other agents on the same machine |

Events land in the `harness_events` datasource (`tool_call`, `error`, `llm_span`, `plan_step`).

## Install in any repo (< 2 min)

```bash
# from your project root
/path/to/synapse ops init --root .
/path/to/synapse dev --root . --port 8787
```

This creates (or reuses) a Synapse workspace, writes `.synapse/ops.json`, and `.synapse/ops.CURSOR.md` with hook hints.

Set identity for multi-agent setups:

```bash
export SYNAPSE_AGENT_ID=cursor
export SYNAPSE_RUN_ID=my-feature-branch
```

## Three capture paths

### 1. MCP (recommended)

Point Cursor MCP at the ops-aware stdio server:

```json
{
  "mcpServers": {
    "synapse-ops": {
      "command": "/path/to/synapse",
      "args": ["ops", "mcp", "--root", "/your/repo"],
      "env": {
        "SYNAPSE_AGENT_ID": "cursor",
        "SYNAPSE_RUN_ID": "my-run"
      }
    }
  }
}
```

Same tools as `synapse mcp`, plus automatic `tool_call` ingest on every `tools/call`.

### 2. Cursor / IDE hooks

See [examples/ops/cursor-hooks.example.json](../examples/ops/cursor-hooks.example.json).  
POST NDJSON lines to `POST /v1/events/harness_events` after each tool use.

### 3. Python decorator

```python
from synapse_sdk import Synapse
from synapse_sdk.instrument import tool_call

s = Synapse("http://127.0.0.1:8787")

@tool_call(s, "run_1", "grep", agent_id="ci-bot")
def grep(q: str) -> str:
    ...
```

### 4. TypeScript `wrapTool`

```typescript
import { Synapse } from "@synapse/sdk";

const s = new Synapse("http://127.0.0.1:8787");
const grep = s.wrapTool("grep", (q: string) => `hits for ${q}`, {
  runId: "run_1",
  agentId: "ts-agent",
});
```

Or batch ingest:

```typescript
await s.ingest("harness_events", [
  { ts: "...", run_id: "run_1", agent_id: "a1", type: "tool_call", payload: { name: "grep", ok: true } },
]);
```

## Query activity

```bash
synapse ops status --root .
curl 'http://127.0.0.1:8787/v1/ops/activity?limit=20'
curl 'http://127.0.0.1:8787/v1/ops/activity?agent_id=cursor&run_id=my-run'
```

Response shape:

```json
{
  "agents": [{ "agent_id": "cursor", "events": 12, "tool_calls": 10, "errors": 1 }],
  "events": [ /* recent harness_events rows */ ]
}
```

Auth: same as other reads — `QUERY:READ` (or `PIPES:READ` / `ADMIN`) when `SYNAPSE_REQUIRE_AUTH=1`.

## Files written by `ops init`

| File | Purpose |
|---|---|
| `.synapse/ops.json` | Version, datasource, base_url, capture list, identity env keys |
| `.synapse/ops.CURSOR.md` | Cursor-specific MCP + hook instructions |

## E2E

```bash
./scripts/e2e_ops.sh
```
