# Fan Playback UI (Dev)

This repo includes a minimal Next.js App Router UI in `audistro-web/` for local playback testing.

## What It Does

1. User enters an asset ID.
2. UI calls `GET /api/playback/{assetId}` and receives ranked providers.
3. UI requests token via `POST /api/access/{assetId}`.
4. UI tries providers in order and uses HLS source:
   - `/api/playlist/{assetId}?providerId=<provider_id>&token=<access_token>`
5. Playlist route fetches playback server-side again, validates `providerId` against trusted catalog providers, fetches provider `master.m3u8`, rewrites key URI from catalog `key_uri_template`, and appends `token` query param for dev key access.
6. Provider fallback rules:
   - manifest fail (`MANIFEST_LOAD_ERROR`/`MANIFEST_LOAD_TIMEOUT`, non-200, timeout) => switch provider
   - segment fail (`FRAG_LOAD_ERROR`/`FRAG_LOAD_TIMEOUT`) >= 2 consecutive => switch provider
   - segment 404/5xx => switch provider immediately
7. Key unauthorized rule:
   - key endpoint `401` or `KEY_LOAD_ERROR` with `401` => refresh token once and retry
   - `maxTokenRefreshAttempts = 1` per Play click
8. `maxProviderSwitches = min(3, providers.length)` to prevent loops.
9. `hls.js` plays on a `<video controls>` element.
10. Boost/Tip flow on `/asset/{assetId}`:
   - user selects amount and clicks **Generate Invoice**
   - UI calls `POST /api/boost` with `{ assetId, amountSats }`
   - server route fetches catalog playback, derives trusted `asset.pay.fap_url` + `asset.pay.fap_payee_id`, then calls FAP `POST /v1/boost`
   - UI renders `bolt11`, QR, and polls `GET /api/boost/{boostId}?assetId=...` every 2s
   - dev-only button calls `POST /api/boost/{boostId}/mark_paid?assetId=...`

## Debug Panel

The player includes a collapsible Debug panel with:

- `assetId`
- current status (`Idle`, `LoadingPlayback`, `FetchingToken`, `LoadingManifest`, `Playing`, `SwitchingProvider`, `RefreshingToken`, `Failed`)
- selected provider (`provider_id` + base URL)
- deterministic attempt log:
  - `providerId`, `baseUrl`, `startedAt`, `endedAt`, `outcome`
  - `failureReason` with fallback trigger (`manifest fail`, `segment fail`, `key unauthorized`)
  - per-attempt error subset
- rolling error list (max 20), each with:
  - `kind`, `type`, `details`, `fatal`, `responseCode`, sanitized `url`, `providerId`, `timestamp`
- playlist source URL
- token `expires_at`

Use **Copy debug JSON** to copy diagnostics for issue reports.

## Boost Panel

On `/asset/{assetId}` the page includes a **Boost / Tip** panel:

- presets: `100`, `500`, `1000` sats + custom amount
- invoice render:
  - `bolt11`
  - QR code
  - `pending|paid|expired|failed` status
- polling timeout: 2 minutes
- dev convenience:
  - **Mark Paid (Dev)** is shown when `NEXT_PUBLIC_DEV_MODE=true` (or non-production runtime)

No token or invoice is persisted to browser storage. A small receipt list is kept in memory only.

## Boost History / Audit Trail

The asset page also includes a **Boost history** panel sourced from:

- `GET /api/boost/list?assetId=...`
- server route derives trusted `fap_url` + `fap_payee_id` from catalog playback
- server calls FAP `GET /v1/boost?asset_id=...&payee_id=...`

Displayed fields:

- amount (sats)
- status (`pending|paid|expired|failed`)
- created timestamp
- paid timestamp
- destination `payee_id`

The panel supports manual refresh and auto-refresh every 10 seconds while at least one item is pending.

## Spend Dashboard (P5)

Route: `/me/spend`

Purpose:

- device-scoped transparency view ("Where did my money go")
- aggregates paid `ledger_entries` from FAP for the current browser device identity (`fap_device_id` cookie)

Server routes used:

- `GET /api/me/ledger`
  - proxies to `GET /v1/ledger`
  - validates query params, clamps `limit` to max `100`
  - forwards device cookie to FAP
- `GET /api/me/spend-summary`
  - pages through `GET /v1/ledger` (`status=paid`, max 10 pages)
  - computes totals:
    - `total_paid_msat_access`
    - `total_paid_msat_boost`
    - `total_paid_msat_all`
  - computes top lists:
    - `top_assets` (with catalog labels from `GET /v1/assets/{assetId}`)
    - `top_payees` (payee id + best-effort artist label)

UI panels:

- totals (access vs boost vs all)
- top assets (linked to `/asset/{assetId}`)
- top payees
- recent paid ledger entries

Window selector:

- last 7 days
- last 30 days

Security notes:

- client never submits service URLs
- server routes use configured `CATALOG_BASE_URL` / `FAP_BASE_URL`
- no token/secret persistence in localStorage
- dashboard data is scoped to current device cookie only (no user account system yet)

## Dev Security Note

The playlist rewrite appends access tokens to key URIs as query params for deterministic local playback. This is **dev-only** behavior and must not be used in production.

Boost route SSRF guard:

- client does **not** send arbitrary `fapUrl`
- `/api/boost*` routes derive FAP target from trusted catalog playback pay hints
- request params (`assetId`, `boostId`, amount bounds) are validated and outbound requests use `AbortController` timeouts

## Dev Admin Payees (M7b)

Dev-only page: `/admin/payees`

- gate is enforced on page and server routes:
  - `NEXT_PUBLIC_DEV_ADMIN=true`
  - `NODE_ENV=development`
- routes:
  - `GET /api/admin/artists` (catalog `GET /v1/browse/artists` proxy)
  - `POST /api/admin/payees` (creates FAP payee + creates catalog payee mapping)

Security behavior:

- LNbits base URL is validated against allowlist `DEV_ADMIN_ALLOW_LNBITS_BASE_URLS`
- host restrictions are enforced (`http://lnbits:5000` and `http://localhost:<port>` patterns only)
- LNbits keys are write-only and never returned to client after save
- client cannot submit arbitrary upstream targets; server uses configured `CATALOG_BASE_URL` / `FAP_BASE_URL`

Local env example (`audistro-web/.env.local`):

- `NEXT_PUBLIC_DEV_ADMIN=true`
- `DEV_ADMIN_ALLOW_LNBITS_BASE_URLS=http://lnbits:5000,http://localhost:5000,http://localhost:18090,http://localhost:18085`
- `NEXT_PUBLIC_FAP_PUBLIC_BASE_URL=http://localhost:18081`
- `NEXT_PUBLIC_DEV_ADMIN_DEFAULT_LNBITS_BASE_URL=http://lnbits:5000`

## Compose Wiring

`docker-compose.yml` includes an `audistro-web` service on `http://localhost:3000` with:

- `CATALOG_BASE_URL=http://audistro-catalog:8080`
- `FAP_BASE_URL=http://audistro-fap:8080`
- `PROVIDER_INTERNAL_BASE_URL=http://audistro-provider:8080` (used by server-side playlist fetch fallback)

CORS is enabled for browser-origin requests from `http://localhost:3000`:

- `env/audistro-provider.env`
  - `PROVIDER_ENABLE_CORS=true`
  - `PROVIDER_CORS_ALLOWED_ORIGINS=http://localhost:3000`
- `env/fap.env`
  - `FAP_ENABLE_CORS=true`
  - `FAP_CORS_ALLOWED_ORIGINS=http://localhost:3000`

## Run

```bash
docker compose up -d --build
```

Open `http://localhost:3000`.

## UI Smoke

```bash
./scripts/test-ui.sh
```

This script runs backend smoke setup first, then checks:

- `GET http://localhost:3000/` returns `200`
- `GET http://localhost:3000/api/playback/asset1` returns `200`
