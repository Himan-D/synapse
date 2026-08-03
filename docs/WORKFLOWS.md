# Durable Workflows

Synapse workflows are **Temporal / Inngest-shaped**, but local-first and graph-native:

```
workflows/*.workflow.json  →  durable run state  →  /v1/workflow-runs/*
```

They sit beside pipes — pipes are sync transforms; workflows are durable async state machines that can call pipes, sleep, wait for signals, and retry.

## Step kinds

| Kind | Behavior |
|---|---|
| `action` | Run a pipe (`pipe`) or POST `http://` (`url`) |
| `sleep` | Pause `ms` milliseconds (survives process restart via `wake_at_ms`) |
| `wait_event` | Block until `POST .../signal` with matching `type` (optional `timeout_ms`) |
| `fanout` | Reserved (v1 sequential stub) |
| `noop` | Marker / no-op |

Default retry: `max_attempts`, `backoff_ms`, `backoff_mult` (per-workflow or per-step).

## Example

See `examples/harness/workflows/demo.workflow.json`:

1. `recall_context` pipe  
2. sleep 10ms  
3. wait for `human.approved`  
4. `plan_goal` pipe  
5. noop done  

## CLI

```bash
synapse workflow list --root examples/harness
synapse workflow start demo --root examples/harness --run-id wf_demo
synapse workflow tick --root examples/harness --run-id wf_demo
synapse workflow signal wf_demo --type human.approved --payload '{"ok":true}' --root examples/harness
synapse workflow status wf_demo --root examples/harness
```

## HTTP

| Method | Path |
|---|---|
| GET | `/v1/workflows` |
| GET | `/v1/workflows/{name}` |
| POST | `/v1/workflows/{name}/runs` body `{ "input", "run_id"? }` |
| GET | `/v1/workflow-runs` |
| GET | `/v1/workflow-runs/{id}` |
| POST | `/v1/workflow-runs/{id}/signal` body `{ "type", "payload"? }` |
| POST | `/v1/workflow-runs/{id}/cancel` |
| POST | `/v1/workflow-runs/{id}/tick` |
| POST | `/v1/workflows/tick` |

`synapse dev` ticks waiting runs between accepts (sleeps/retries advance without a client poll).
