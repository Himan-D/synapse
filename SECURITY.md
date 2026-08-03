# Security Policy

## Supported versions

Synapse is pre-1.0. Only the latest `0.1.x` release receives security fixes;
there are no long-term support branches yet.

| Version | Supported |
|---|---|
| `0.1.x` (latest) | Yes |
| Anything older | No — upgrade |

## Reporting a vulnerability

Report privately through **GitHub Security Advisories**: open the repository's
**Security** tab → **Report a vulnerability**. That keeps the report and the fix
non-public until a patched release exists.

Please do not open a public issue or pull request for a suspected
vulnerability.

Useful details: affected version (`GET /health` returns it), whether `SYNAPSE_REQUIRE_AUTH` was enabled, the bind address,
whether it was `synapse dev` or `synapse cloud serve`, and a reproduction — a
`curl` invocation is ideal.

Expect an acknowledgement within a few business days. Since this is a small
project, no bounty is offered.

## What is in scope

- Auth bypass: reaching a scoped route without a valid token, or with a token
  minted for a different workspace or a narrower scope.
- Cross-workspace data leakage in `cloud serve`.
- Path traversal via datasource, checkpoint, workspace, or pipe names.
- Crashes, hangs, or unbounded memory growth reachable from an unauthenticated
  HTTP request.
- Secrets written to logs, or to files with overly permissive contents.

## What is not a vulnerability

These are documented, intentional behaviors. Reports about them will be closed
as working-as-intended.

- **Auth is off by default on loopback.** `synapse dev` binds `127.0.0.1` and
  does not require a token unless `SYNAPSE_REQUIRE_AUTH=1` is set. That is a
  local-development default. It is not an exposure on its own: reaching it
  already requires code execution on the host or a deliberately opened port.
  `synapse cloud serve` refuses to bind a non-loopback address without
  `SYNAPSE_REQUIRE_AUTH=1`, and `synapse dev` warns when you do.
- **The local dev token in `.synapse/token`** is a plaintext file with a random
  per-workspace value, readable by the user running the server. It authorizes
  only single-root dev mode; `cloud serve` never consults it. Cloud-scaffolded
  workspaces get no local token.
- **`platform.json` stores tokens in plaintext.** It is the credential store for
  cloud mode and is expected to live on a private disk with normal filesystem
  permissions. Treat it as a secret. Hashed-at-rest tokens are not implemented.
- **`?token=` in a query string.** Supported for clients that cannot set
  headers, and it will appear in access logs and proxy logs. Prefer
  `Authorization: Bearer`.
- **No TLS.** Synapse speaks plain HTTP by design; terminate TLS at your load
  balancer, reverse proxy, or platform (Render does this for you).
- **No rate limiting unless configured.** Set `SYNAPSE_RATE_LIMIT=<req/s>`.
- **No token expiry or revocation endpoint.** To revoke, remove the entry from
  `platform.json` and restart. Tracked in `docs/PRODUCTION_PLAN.md`.
- **Pipe definitions are trusted input.** Anyone who can write `pipes/*.pipe.json`
  in a workspace already controls what that workspace computes and where its
  `sink` nodes POST. Treat workspace write access as equivalent to code access.

## Hardening checklist for deployments

1. Set `SYNAPSE_REQUIRE_AUTH=1` (required by `cloud serve` off loopback; the
   Docker image sets it).
2. Terminate TLS in front of Synapse.
3. Mint the narrowest scope that works — `EVENTS:WRITE` for ingest-only agents,
   `PIPES:READ` for readers — rather than reusing `ADMIN`.
4. Keep the platform `admin_token` out of application configs; it is
   control-plane-only.
5. Put `platform.json` and workspace data on a persistent, private disk. Never
   bake them into an image or commit them.
6. Set `SYNAPSE_RATE_LIMIT` for any internet-reachable deployment.
7. Ship the JSON access log (`ts`, `request_id`, `method`, `path`, `status`,
   `duration_ms`) somewhere you can query it.
