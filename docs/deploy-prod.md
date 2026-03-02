# Deploy Production Reference

This is a hardened reference deployment. It does not replace service-specific runbooks.

## Topology

Reference files:
- [`docker-compose.prod.yml`](../docker-compose.prod.yml)
- [`caddy/Caddyfile`](../caddy/Caddyfile)
- [`docs/production-readiness.md`](./production-readiness.md)

Public routing:
- `https://$WEB_HOST` -> `audistro-web`
- `https://$API_HOST/catalog/*` -> `audistro-catalog`
- `https://$API_HOST/fap/*` -> `audistro-fap`
- `https://$PROVIDER_EU_1_HOST` -> `audistro-provider_eu_1`
- `https://$PROVIDER_EU_2_HOST` -> `audistro-provider_eu_2`
- `https://$PROVIDER_US_1_HOST` -> `audistro-provider_us_1`

Internal rules:
- `/internal/*` is blocked at Caddy
- service-to-service traffic stays on the internal compose network
- catalog/FAP admin endpoints stay disabled in prod configs

## Prepare Env Files

Create explicit prod env files under `env/prod/`:
- `env/prod/audistro-catalog.env`
- `env/prod/fap.env`
- `env/prod/audistro-provider_eu_1.env`
- `env/prod/audistro-provider_eu_2.env`
- `env/prod/audistro-provider_us_1.env`

Use `env/example/*.example.env` as templates, then replace all placeholders with real values.

Required differences from dev:
- `CATALOG_ENV=prod`
- `NEXT_PUBLIC_DEV_ADMIN=false`
- `FAP_DEV_MODE=false`
- HTTPS public base URLs only
- exact `*_INTERNAL_ALLOWED_CIDRS` values
- non-dev secrets everywhere

## Prepare Secrets

Create at minimum:
- `secrets/fap_token_secret`
- `secrets/origin_hmac_secret`

Keep them out of git and provision them through your secret manager or deployment automation.

## Deploy

```bash
cd /home/goku/code/audistro-dev
export ACME_EMAIL=ops@example.com
export WEB_HOST=app.example.com
export API_HOST=api.example.com
export PROVIDER_EU_1_HOST=provider-eu-1.example.com
export PROVIDER_EU_2_HOST=provider-eu-2.example.com
export PROVIDER_US_1_HOST=provider-us-1.example.com

docker compose -f docker-compose.prod.yml up -d --build
```

## Verify

```bash
curl -fsS https://$API_HOST/catalog/healthz
curl -fsS https://$API_HOST/fap/healthz
curl -fsS https://$PROVIDER_EU_1_HOST/readyz
curl -fsS https://$PROVIDER_EU_1_HOST/metrics
```

Internal endpoint block check:

```bash
curl -i https://$API_HOST/fap/internal/assets/test/packaging-key
curl -i https://$PROVIDER_EU_1_HOST/internal/rescan
```

Both should be blocked by the edge proxy.

## Notes

- This is a reference compose deployment, not an HA design.
- SQLite remains operationally acceptable only while backup/restore and write contention stay simple.
- For higher write volume or stricter recovery targets, plan the move to Postgres.
