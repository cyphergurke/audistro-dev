# Runtime Environment Configuration

## Runtime env mode

`AUDISTRO_ENV` is the single runtime mode signal across `audistro-fap`, `audistro-catalog`, `audistro-provider`, and `audistro-web`.

Allowed values:

- `prod`
- `dev`
- `test`

Rules:

- `docker-compose.prod.yml` must set `AUDISTRO_ENV=prod` for every audistro service.
- Dev compose must set `AUDISTRO_ENV=dev` explicitly.
- In `prod`, each service validates its own `ops/env.schema.json` before HTTP startup and exits with code `1` on missing or invalid required env keys.
- Validation errors must be single-line and must not print secret values.
- Existing service-specific env flags may still exist for backwards compatibility, but `AUDISTRO_ENV` is the canonical runtime mode signal.
