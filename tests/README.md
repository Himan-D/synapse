# Tests

Unit tests live inline next to Zig modules (`zig build test`).

Workspace / verb integration coverage:

```bash
./zig-out/bin/synapse test --root examples/harness
./scripts/e2e.sh
```

Cloud security and multi-workspace isolation:

```bash
./scripts/e2e_cloud.sh
```

`e2e_cloud.sh` covers:
- `dev-token-local` absent from cloud-scaffolded workspace directories
- no token → 401; unknown token → 401
- valid token for wrong workspace → 403 (not 401, not 200)
- valid token for correct workspace → 200
- platform admin token required for `/v1/platform/*`; non-admin → 403
- data written to workspace A is not visible from workspace B
- `cloud serve` on a non-loopback address without `SYNAPSE_REQUIRE_AUTH=1` exits non-zero

CI runs all three suites (see `.github/workflows/ci.yml`).
