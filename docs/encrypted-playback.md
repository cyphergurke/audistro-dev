# Encrypted Playback

This guide validates Phase 2.2 encrypted playback and encrypted multi-provider failover.

## Deterministic Smoke

Run the failover smoke:

```bash
cd /home/goku/code/audistro-dev
./scripts/smoke-encrypted-failover.sh
```

Manual payment setup path if the encrypted asset does not exist yet:

```bash
cd /home/goku/code/audistro-dev
./scripts/smoke-encrypted-failover.sh --wait-manual
```

What it proves:
- an encrypted asset exists on the provider
- the same encrypted asset is available on at least two providers
- that multi-provider presence comes from the normal ingest fanout publish, not a manual copy step
- provider[0] can fail on segment fetch while provider[1] still serves the asset
- public playlists still point to FAP for `EXT-X-KEY`
- web `/api/playlist` rewrites the key URI to `/api/hls-key/{assetId}`

Use a specific asset:

```bash
cd /home/goku/code/audistro-dev
ASSET_ID=asset_smoke_upload_encrypt_pay ./scripts/smoke-encrypted-failover.sh
```

Optional provider fanout presence check:

```bash
cd /home/goku/code/audistro-dev
ASSET_ID=asset_smoke_upload_encrypt_pay ./scripts/assert-asset-on-providers.sh
```

## Manual Browser Check

1. Open `http://localhost:3000/asset/<assetId>`.
2. Click `Run encrypted playback preflight`.
3. If payment is required, pay the invoice and wait for token issuance.
4. Wait for these expected results:
   - `Playback metadata`: `PASS`
   - `Access token`: `PASS`
   - `Playlist fetch`: `PASS`
   - `Key proxy fetch`: `PASS`
   - `First segment fetch`: `PASS`
   - `Fallback readiness`: `PASS`
5. Click `Play`.
6. Confirm audio starts.

## Expected UI Signals

Healthy encrypted playback:
- provider shown in the player debug block
- no persistent `Last error`
- preflight summary says `encrypted playback preflight passed`

Fallback exercised:
- preflight provider list shows provider[0] segment failure and a later provider success
- player status transitions through `SwitchingProvider` and then reaches `Playing`

## Common Failure Signatures

CORS:
- provider segment fetch fails from the browser with `403` or CORS console errors
- check `PROVIDER_CORS_ALLOWED_ORIGINS`

401 unauthorized:
- `/api/hls-key` or `/api/playlist` returns `401`
- usually missing token or expired token

403 `device_mismatch`:
- token exists but device cookie does not match the grant context

403 `payment_required` or `grant_expired`:
- token acquisition or key fetch is denied because access is unpaid or expired

404 on segment:
- encrypted playlist exists on one provider but the fanout publish or announce path did not make the asset available on the fallback provider

Key URI not rewritten:
- `/api/playlist` still contains the raw FAP key URL instead of `/api/hls-key/...`
- check the same-origin playlist rewrite path in web

Range / media load issues:
- preflight passes but browser playback still stalls
- inspect browser network tab for HLS fragment/range requests and hls.js errors
