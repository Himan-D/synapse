# Ops capture — who did what

Synapse **ops** is drop-in agent activity logging for any repo. After `synapse ops init`, capture wiring is written automatically — hooks, MCP config, and status are always visible in the repo.

## Honest limits

| Captured when wired | Not captured automatically |
|---|---|
| MCP `tools/call` via `synapse ops mcp` | Every keystroke or chat message |
| Cursor/Claude hooks you configure | Built-in editor tools unless hooked |
| Python `@tool_call` / TS `wrapTool()` | File reads the agent never reports |
| Direct `POST /v1/events/harness_events` | Other agents on the same machine |

Events land in the `harness_events` datasource (`tool_call`, `error`, `llm_span`, `plan_step`).

**Not spyware** — nothing is hidden. All wiring lives in `.synapse/ops.json`, `.cursor/hooks.json`, and `.synapse/ops.mcp.json`. Check anytime with `synapse ops status`.

## Install in any repo (< 2 min)

```bash
# from your project root
/path/to/synapse ops init --root .
/path/to/synapse dev --root . --port 8787
```

This creates (or reuses) a Synapse workspace and writes:

| File | Purpose |
|---|---|
| `.synapse/ops.json` | Capture config (`enabled: true`) |
| `.cursor/hooks.json` | Cursor afterToolUse hook |
| `.synapse/ops.mcp.json` | MCP server snippet for Cursor |
| `.synapse/ops.CURSOR.md` | Setup notes |

Set identity for multi-agent setups:

```bash
export SYNAPSE_AGENT_ID=cursor
export SYNAPSE_RUN_ID=my-feature-branch
```

## Three capture paths

### 1. MCP (recommended)

Merge `.synapse/ops.mcp.json` into Cursor MCP settings, or point at:

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

Written automatically to `.cursor/hooks.json` by `ops init`.  
See also [examples/ops/cursor-hooks.example.json](../examples/ops/cursor-hooks.example.json).

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

## Optional transcript watch

```bash
synapse ops watch --root .              # one scan
synapse ops watch --root . --follow     # poll SYNAPSE_TRANSCRIPT_DIR
export SYNAPSE_TRANSCRIPT_DIR=~/.cursor/projects/my-project/agent-transcripts
```

Gracefully skips if no transcript directory is found.

## Query activity

```bash
synapse ops status --root .
curl 'http://127.0.0.1:8787/v1/ops/activity?limit=20'
curl 'http://127.0.0.1:8787/v1/ops/activity?agent_id=cursor&run_id=my-run'
```

Status includes: `ops_config`, `capture_enabled`, `hooks_installed`, `mcp_config_present`, `last_event_ts`, per-agent counts.

Response shape for activity:

```json
{
  "agents": [{ "agent_id": "cursor", "events": 12, "tool_calls": 10, "errors": 1 }],
  "events": [ /* recent harness_events rows */ ]
}
```

Auth: same as other reads — `QUERY:READ` (or `PIPES:READ` / `ADMIN`) when `SYNAPSE_REQUIRE_AUTH=1`.

## E2E

```bash
./scripts/e2e_ops.sh
```
