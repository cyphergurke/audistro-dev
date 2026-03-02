# E2E Playback Smoke Test

## Topology

The smoke stack runs with Docker Compose:

- `audistro-catalog` on `http://localhost:18080`
- `audistro-fap` on `http://localhost:18081`
- `audistro-provider_eu_1` on `http://localhost:18082`
- `audistro-provider_eu_2` on `http://localhost:18083`
- `audistro-provider_us_1` on `http://localhost:18084`

Each provider uses its own persistent volume mounted at `/var/lib/audistro-provider`.

## What The Script Validates

`scripts/smoke-e2e-playback.sh` verifies:

1. Compose boot and health checks for all services.
2. Catalog SQLite schema readiness and base metadata seeding (`artists`, `payees`, `assets`).
3. HLS fixture generation and deployment:
   - valid HLS on `audistro-provider_eu_1`
   - valid HLS on `audistro-provider_eu_2`
   - asset absent on `audistro-provider_us_1`
4. Provider internal triggers on all providers:
   - `POST /internal/rescan`
   - `POST /internal/announce`
5. Catalog playback response contains multiple providers for the asset.
6. Deterministic fallback simulation:
   - inject failure on `audistro-provider_eu_2` by removing one referenced segment after announce
   - assert broken provider: `master.m3u8` is `200`, first segment is non-`200`
   - assert healthy provider: `master.m3u8` is `200`, first segment is `200`
   - log explicit fallback PASS line
7. FAP integration sanity:
   - if `FAP_DEV_MODE=true`, the script also verifies `POST /v1/access/{assetId}` and `GET /hls/{assetId}/key`
   - if `FAP_DEV_MODE=false`, the script logs a skip for the dev-access endpoint and leaves non-dev key validation to `scripts/smoke-paid-access.sh`

## Boost Dev Check (Manual)

After stack is up, validate boost stubs via UI:

1. Open `http://localhost:3000/asset/asset1`
2. In **Boost / Tip**, generate invoice (for example `1000` sats)
3. Confirm `bolt11`, QR and `pending` status are visible
4. Click **Mark Paid (Dev)** and confirm status turns to `paid` within the next poll

## M7b Dev Admin Payee Setup (Optional)

If you want real LNbits boost invoices (M7 flow), seed payees via UI:

1. Run the web app in dev mode (`pnpm dev`) with `NEXT_PUBLIC_DEV_ADMIN=true`
2. Open `http://localhost:3000/admin/payees`
3. Select or enter `artist_id`
4. Enter LNbits fields (`lnbits_base_url`, invoice key, read key)
5. Save and keep returned identifiers (`fap_payee_id`, optional `catalog_payee_id`)

This avoids manual DB writes for payee provisioning.

## Run

```bash
./scripts/smoke-e2e-playback.sh
```

Optional override:

```bash
ASSET_ID=asset1 WAIT_SECONDS=120 ./scripts/smoke-e2e-playback.sh
```

## Paid Access Smoke (M7e)

For non-dev challenge/invoice/token flow, run:

```bash
./scripts/smoke-paid-access.sh
```

Details: see [`docs/smoke-paid-access.md`](./smoke-paid-access.md).

## Encrypted Ingest + Paid Access Smoke

For the full Phase 2 pipeline, run:

```bash
./scripts/smoke-upload-encrypt-pay.sh
```

Manual payment mode:

```bash
./scripts/smoke-upload-encrypt-pay.sh --wait-manual
```

Details: see [`docs/smoke-upload-encrypt-pay.md`](./smoke-upload-encrypt-pay.md).

## Encrypted Playback + Failover Validation

For Phase 2.2 encrypted playback and multi-provider failover, run:

```bash
./scripts/smoke-encrypted-failover.sh
```

If the encrypted asset still needs a manual payment bootstrap:

```bash
./scripts/smoke-encrypted-failover.sh --wait-manual
```

Details: see [`docs/encrypted-playback.md`](./encrypted-playback.md).

The failover smoke now expects a normal encrypted upload to fanout-publish the asset to both `audistro-provider_eu_1` and `audistro-provider_eu_2`; it no longer copies assets between provider volumes as a setup step.

## Notes

- This is dev-only smoke coverage.
- The script requires `docker` and `curl`, plus `jq` or `python3`.
- For non-dev paid access/key validation, use `./scripts/smoke-paid-access.sh` or `./scripts/ci-gates.sh smoke`.
- `audistro-catalog` currently enforces HTTPS for signed provider announce URLs. In this local HTTP setup the script still triggers announce endpoints, then upserts provider registry rows in SQLite using the providers' runtime identities so fallback behavior remains deterministic.
