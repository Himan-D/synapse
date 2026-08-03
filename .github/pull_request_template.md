## What changed

<!-- One or two sentences. What does this do that the repo could not do before? -->

## Why

<!-- The problem or gap. Link an issue if there is one. -->

## Verification

Paste or confirm the loop from CONTRIBUTING.md:

- [ ] `zig fmt --check src/ build.zig`
- [ ] `zig build && zig build test`
- [ ] `./scripts/e2e.sh`
- [ ] `./scripts/e2e_cloud.sh`

## If this touches an HTTP route or a scope

- [ ] Handler updated (`src/server/http.zig`)
- [ ] `docs/openapi.yaml` updated — every status code the handler can return
- [ ] e2e assertion added, covering both the success path and the new rejection

## Docs

- [ ] No unimplemented flags or endpoints appear in any example
- [ ] Anything still roadmap is labeled roadmap
