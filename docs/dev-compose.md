# Dev Compose Deployment

This repo root contains a development Docker Compose setup for:
- `audistro-catalog`
- `audistro-fap`
- `audistro-provider`

## Files

- `docker-compose.yml`
- `env/audistro-catalog.env`
- `env/fap.env`
- `env/audistro-provider.env`
- `secrets/origin_hmac_secret`
- `scripts/smoke.sh`

## Port map

- `audistro-catalog`: `http://localhost:18080`
- `audistro-fap`: `http://localhost:18081`
- `audistro-provider`: `http://localhost:18082`

Container-to-container DNS wiring:
- `audistro-provider -> audistro-catalog`: `http://audistro-catalog:8080`

## Run

```bash
docker compose up --build -d
```

Check service state:

```bash
docker compose ps
```

Run end-to-end smoke:

```bash
./scripts/smoke.sh
```

Stop:

```bash
docker compose down
```

Stop and remove volumes:

```bash
docker compose down -v
```

## Dev URL note for provider base URL

`audistro-catalog` currently enforces `https` for provider registration and announcement `base_url`.
For this reason, `env/audistro-provider.env` uses:

- `PROVIDER_PUBLIC_BASE_URL=https://localhost:18082`

Even though the dev container serves plain HTTP directly on `localhost:18082`.
The smoke test validates direct HTTP asset fetches from `audistro-provider`.

## Internal endpoint protection

`audistro-provider` keeps internal endpoints CIDR-protected (loopback default):
- `POST /internal/rescan`
- `POST /internal/announce`

`scripts/smoke.sh` calls these from inside the `audistro-provider` container using loopback.

## Contract drift prevention

Root `spec/` is the shared contract layer for cross-repo tests and reviews:

- `spec/provider-announcement.md`: canonical announcement message + validation rules.
- `spec/origin-hmac.md`: HMAC headers and canonical string.
- `spec/testvectors.json`: shared deterministic vectors from current code/tests.
- `spec/playback-bootstrap.schema.json`: explicit schema for `GET /v1/playback/{assetId}`.

Recommended usage:
- Keep tests in each repo consuming `spec/testvectors.json` and `spec/playback-bootstrap.schema.json`.
- Update `spec/` in the same change whenever wire-format behavior changes.
