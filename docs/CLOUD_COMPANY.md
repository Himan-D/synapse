# Synapse Cloud Company — Scorecard

**Goal:** move from “demoable 0.1” toward a sellable hosted product.  
**Honesty rule:** we do not claim 9/10 until customers + ops prove it. This doc is the cut.

## Target maturity (what “9/10” means here)

| Pillar | 9/10 looks like | This pass ships | Explicitly deferred |
|---|---|---|---|
| Tenancy | Isolated workspaces, least-privilege tokens | Done (Phase C) + **hash-at-rest, revoke, list** | SSO / OIDC / SCIM |
| Secrets | Tokens not recoverable from disk | **SHA-256 at rest; plaintext shown once at mint** | HSM / KMS |
| Metering | Usage you can bill on | **Per-workspace request + ingest counters + export API** | Stripe Checkout UI |
| DX | One-shot bootstrap + SDKs | **`scripts/cloud_bootstrap.sh` + `/cloud` admin UI + SDK workspace URLs** | Full console redesign |
| Durability | Survive process death | Local disk + platform.json (existing) | Postgres + object store |
| Ops | CI, health, auth-on by default off-loopback | Existing CI + cloud serve gate | Multi-region HA |
| Compliance | Clear security story | SECURITY.md | SOC2 / HIPAA |
| Market | Real harnesses in prod | Not claimed | Design partners |

## Must build (this pass)

1. Token **hash-at-rest** + **revoke** + **list** (never store raw token after mint response)
2. **Usage metering** per workspace (HTTP requests, ingest events/bytes) + `GET /v1/platform/usage`
3. **Cloud bootstrap** script and **`/cloud`** admin page (orgs/workspaces/tokens/usage) — no fake charts
4. **Python + TS SDKs** accept `workspace_id` and call `/v1/w/{id}/…`
5. Docs scorecard stays truthful about what’s deferred

## Must NOT build (yet)

- Stripe billing portal / invoices (metering API is enough to wire later)
- Kafka, ClickHouse, SQL pipes
- Multi-region / leader election
- Enterprise SSO
- “AI auto-pipe” marketing features
- Replacing Zig with another language

## How to verify

```bash
zig build && zig build test
./scripts/e2e.sh
./scripts/e2e_cloud.sh
./scripts/cloud_bootstrap.sh /tmp/synapse-data
```

When a design partner runs production traffic for 30 days and metering feeds an invoice, revisit the scorecard.
