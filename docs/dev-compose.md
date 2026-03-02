# Dev Compose Deployment

This repo root contains a development Docker Compose setup for:
- `audistro-catalog`
- `audistro-catalog-worker`
- `audistro-fap`
- `audistro-provider`
- `audistro-web`

## Files

- `docker-compose.yml`
- `env/audistro-catalog.env`
- `env/fap.env`
- `env/audistro-provider.env`
- `secrets/origin_hmac_secret`
- `scripts/smoke.sh`

## Port map

- `audistro-catalog`: `http://localhost:18080`
- `audistro-catalog-worker`: internal only
- `audistro-fap`: `http://localhost:18081`
- `audistro-provider_eu_1`: `http://localhost:18082`
- `audistro-provider_eu_2`: `http://localhost:18083`
- `audistro-provider_us_1`: `http://localhost:18084`
- `audistro-web`: `http://localhost:3000`

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

Upload pipeline smoke:

1. Open `http://localhost:3000/admin/bootstrap`
2. Create the artist + payee once
3. Open `http://localhost:3000/admin/upload`
4. Upload an MP3 with the returned `artist_id` and `payee_id`
5. Wait for the ingest job to become `published`
6. Open `/asset/{assetId}` and start playback

Multi-provider upload publish:

- `audistro-catalog-worker` mounts:
  - `audistro-provider_eu_1_data` at `/mnt/providers/eu_1`
  - `audistro-provider_eu_2_data` at `/mnt/providers/eu_2`
- uploaded assets are fanout-published to both provider storage mounts
- the primary `hls_master_url` still points at `eu_1`, while provider announcements make both `eu_1` and `eu_2` available for playback/failover

Encrypted playlist check:

```bash
ASSET_ID=<assetId> ./scripts/check-encrypted-playlist.sh
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

Provider internal endpoints are allowlisted for loopback plus the Docker bridge subnet in dev, so the catalog worker can call `/internal/rescan` and `/internal/announce`.

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
