# Contributing to Synapse

## Prerequisites

- Zig 0.16+
- `curl` and `python3` (the e2e scripts use them for requests and JSON asserts)
- Optional: Python 3.10+ for the SDK / harness examples

## The verification loop

Run these four, in this order, before opening a pull request. CI runs the same
sequence, so a failure here is a failure there.

```bash
zig fmt --check src/ build.zig  # 1. formatting — fix with `zig fmt src/ build.zig`
zig build && zig build test     # 2. compile + unit tests
./scripts/e2e.sh                # 3. local single-root HTTP contract
./scripts/e2e_cloud.sh          # 4. multi-tenant cloud contract + isolation
```

Both e2e scripts start a real server on a scratch port, assert against live
HTTP, and clean up their temp directories and child processes on exit. They are
the only thing standing between a refactor and a silently broken API, so do not
skip step 4 just because your change "isn't cloud" — the cloud path shares the
router, auth, and store with local mode.

Useful extras:

```bash
./zig-out/bin/synapse test --root examples/harness   # pipe assertions in the demo workspace
./scripts/demo.sh                                    # end-to-end product walkthrough
```

## The route → OpenAPI → e2e rule

**Every HTTP surface change must land in all three places in the same commit.**

1. **Route** — the handler in `src/server/http.zig` (plus `src/core/workspace_hub.zig`
   if the change touches workspace resolution or auth).
2. **OpenAPI** — `docs/openapi.yaml`: path, method, auth requirement, request
   and response shape, and every status code the handler can actually return.
   The spec is a contract we publish, not a sketch. If the handler can return
   `403`, the spec says `403`.
3. **e2e** — an assertion in `scripts/e2e.sh`, or `scripts/e2e_cloud.sh` for
   anything under `/v1/platform/*`, `/v1/w/{workspace_id}/*`, or cloud auth.
   Cover the success path *and* the rejection you introduced (wrong scope,
   wrong workspace, missing body).

A route without a spec entry is undocumented. A route without an e2e assertion
is unprotected. Reviewers will ask for both.

The same applies to scopes: the five in `src/core/auth.zig` (`ADMIN`,
`PIPES:READ`, `EVENTS:WRITE`, `REMEMBER:WRITE`, `QUERY:READ`) are the complete
set. Adding one means updating `auth.zig`, the `openapi.yaml` scope enum, the
docs table in `docs/CLOUD.md`, and an e2e case proving the new scope is accepted
where it should be and rejected everywhere else.

## Layout

- `src/core/` — runtime (store, pipes, graph, mind, workflows, platform catalog)
- `src/server/` — HTTP + MCP
- `src/cli/` — CLI commands
- `examples/harness/` — demo workspace
- `sdk/python`, `sdk/typescript` — clients
- `web/` — local playground UI
- `scripts/` — demo and e2e harnesses
- `docs/` — OpenAPI spec, cloud deploy guide, production plan

## Guidelines

- Keep the Tinybird-shaped DX: Datasource → Pipe → Endpoint
- Local-first: single-root mode is the stable path; cloud mode is additive and
  must not change local behavior
- Docs describe what the code does today. No aspirational flags, no unimplemented
  CLI options in examples. If it is roadmap, label it roadmap
- Errors are JSON with a stable `error` string and an accurate status code —
  `401` for unauthenticated, `403` for authenticated-but-forbidden, `404` for
  missing or not-owned resources
- Do not commit `.synapse/data`, exports, tokens, checkpoints, or `platform.json`
- Match existing Zig 0.16 Io / std APIs used in the repo; no new dependencies
