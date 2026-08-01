# Contributing to Synapse

## Prerequisites

- Zig 0.16+
- Optional: Python 3.10+ for the SDK / harness examples

## Develop

```bash
zig build
zig build test
./zig-out/bin/synapse test --root examples/harness
./scripts/e2e.sh
```

## Layout

- `src/core/` — runtime (store, pipes, graph, mind)
- `src/server/` — HTTP + MCP
- `src/cli/` — CLI commands
- `examples/harness/` — demo workspace
- `sdk/python`, `sdk/typescript` — clients
- `web/` — local playground UI

## Guidelines

- Keep the Tinybird-shaped DX: Datasource → Pipe → Endpoint
- Prefer local-first behavior; cloud features stay behind roadmap docs
- Do not commit `.synapse/data`, exports, tokens, or checkpoints
- Match existing Zig 0.16 Io / std APIs used in the repo
