# Production Readiness

This document is the minimum operations checklist for a production-like audistro deployment.

## Secrets

Required before first deploy:
- `FAP_MASTER_KEY_HEX`
- `FAP_ISSUER_PRIVKEY_HEX`
- `FAP_WEBHOOK_SECRET`
- `FAP_ADMIN_TOKEN`
- `FAP_TOKEN_SECRET_PATH` file contents
- `PROVIDER_ORIGIN_HMAC_SECRET_PATH` file contents when origin auth is enabled
- provider identity persistence (`provider_identity.json` per provider volume)
- LNbits per-payee credentials, stored through FAP payee setup, not in service envs
- `CATALOG_ADMIN_TOKEN` only for controlled dev/admin environments

Rules:
- production env files must not reuse dev tokens or localhost URLs
- `/internal/*` endpoints must stay private-network only
- dev-only admin routes must be disabled in prod by environment (`CATALOG_ENV=prod`, `NEXT_PUBLIC_DEV_ADMIN=false`, `FAP_DEV_MODE=false`)

## Backup And Restore

Current storage is SQLite + persistent volumes.

Back up at minimum:
- catalog volume: `/var/lib/audistro-catalog`
- FAP volume: `/var/lib/fap`
- provider volumes: `/var/lib/audistro-provider`
- secrets used for token/HMAC material

SQLite backup approach:
1. stop writes or snapshot the volume atomically
2. copy `.db` files and the full volume contents together
3. keep provider identity files with provider DB/assets
4. test restore into a staging stack before calling the backup valid

Restore checklist:
1. restore volumes into clean containers
2. restore secret files with original values
3. boot services one by one and verify `/healthz` and provider `/readyz`
4. verify FAP can still validate existing grants and provider identities remain stable

Medium-term plan:
- move catalog/FAP to managed Postgres when concurrent write load, backups, and failover requirements outgrow SQLite operational comfort

## Rotation Strategy

Current state:
- `FAP_MASTER_KEY_HEX` rotation is not implemented in-place
- token secret rotation requires coordinated rollout and token expiry window planning
- provider origin HMAC rotation should support overlapping accept windows at the proxy/origin boundary

Operational recommendation:
- rotate admin tokens and webhook secrets first; they are low-risk compared to master key rotation
- treat master key rotation as a planned migration project, not an ad hoc secret swap
- keep a dated secret inventory with owners and last-rotation timestamps

## Observability Baseline

Available now:
- provider: `/healthz`, `/readyz`, `/metrics`
- catalog: `/healthz`
- FAP: `/healthz`
- catalog/FAP/provider access logs should be shipped from stdout/stderr

Recommended baseline:
- central log sink with request-id preservation
- alert on provider `/readyz` and FAP/catalog `/healthz`
- alert on repeated 401/403 rates for key/token/internal endpoints
- alert on ingest job failures and provider announce drift

## CI Gates

Primary local entrypoint:

```bash
cd /home/goku/code/audistro-dev
./scripts/ci-gates.sh unit
CI=1 SKIP_MANUAL=1 ./scripts/ci-gates.sh smoke
CI=1 SKIP_MANUAL=1 ./scripts/ci-gates.sh all
```

What runs:
- `unit`: Go tests for `audistro-fap`, `audistro-catalog`, `audistro-provider`; web `pnpm test`, `pnpm typecheck`, `pnpm build`
- `smoke`: `smoke-e2e-playback.sh`, `smoke-paid-access.sh`, `smoke-upload-encrypt-pay.sh`, `smoke-encrypted-failover.sh`

Behavior:
- `CI=1` shortens smoke wait times and log verbosity
- `SKIP_MANUAL=1` converts payment-dependent smokes into clean skips when payer/LNbits secrets are absent
- if payer secrets are present, the paid smokes run instead of skipping

## Dev vs Prod Separation

Dev stack:
- host ports on localhost
- permissive docker-network CIDRs only in dev env files
- dev admin endpoints enabled

Prod stack:
- no localhost public URLs
- no broad private CIDRs by default; set exact ranges explicitly
- no dev admin endpoints exposed
- reverse proxy terminates TLS and blocks `/internal/*`
