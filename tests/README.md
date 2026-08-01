# Tests

Unit tests live inline next to Zig modules (`zig build test`).

Workspace / verb integration coverage:

```bash
./zig-out/bin/synapse test --root examples/harness
./scripts/e2e.sh
```

CI runs both (see `.github/workflows/ci.yml`).
