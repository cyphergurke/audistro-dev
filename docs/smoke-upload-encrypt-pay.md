# Smoke: Upload -> Encrypt -> Pay

`scripts/smoke-upload-encrypt-pay.sh` validates the full Phase 2 dev flow:

1. boot the compose stack
2. bootstrap or reuse an artist/payee mapping
3. upload an MP3 into catalog ingest
4. wait for the worker to publish encrypted HLS to the provider
5. assert the playlist contains `#EXT-X-KEY:METHOD=AES-128`
6. assert the key URI points to the configured FAP public URL
7. create a non-dev paid-access challenge in FAP
8. pay the invoice automatically through LNbits, or wait for manual payment
9. exchange the challenge for an access token
10. fetch `/hls/{assetId}/key` with bearer token and device cookie and assert `16` bytes
11. fetch the first provider segment and assert `200`

The smoke proves the encrypted ingest and authorization path. It does not decode media.

## Run

Automated payment:

```bash
cd /home/goku/code/audistro-dev
LNBITS_PAYER_ADMIN_KEY=... ./scripts/smoke-upload-encrypt-pay.sh
```

Manual payment:

```bash
cd /home/goku/code/audistro-dev
./scripts/smoke-upload-encrypt-pay.sh --wait-manual
```

## Inputs

The script reads these from the local dev repo when available:
- [`env/audistro-catalog.env`](/home/goku/code/audistro-dev/env/audistro-catalog.env)
  - `CATALOG_ADMIN_TOKEN`
- [`env/fap.env`](/home/goku/code/audistro-dev/env/fap.env)
  - `FAP_WEBHOOK_SECRET`
  - fallback LNbits keys
- `secrets/lnbits_invoice_key`
- `secrets/lnbits_read_key`
- `secrets/lnbits_payer_admin_key`

Important env overrides:
- `CATALOG_BASE_URL` default: `http://localhost:18080`
- `FAP_BASE_URL` default: `http://localhost:18081`
- `PROVIDER_BASE_URL` default: `http://localhost:18082`
- `FAP_PUBLIC_BASE_URL` default: `http://localhost:18081`
- `LNBITS_BASE_URL` default: `http://localhost:18090` when reachable, otherwise `http://localhost:5000`
- `LNBITS_BASE_URL_PAYEE` default: `http://lnbits:5000`
- `LNBITS_INVOICE_KEY_PAYEE`
- `LNBITS_READ_KEY_PAYEE`
- `LNBITS_PAYER_ADMIN_KEY`
- `WAIT_SECONDS` default: `240`
- `SOURCE_AUDIO_FILE` optional; otherwise a deterministic sine-wave MP3 is generated

## Payment Modes

Automated mode:
- requires `LNBITS_PAYER_ADMIN_KEY`
- pays the returned Bolt11 through LNbits automatically
- if LNbits rejects the payment attempt, the script falls back to manual mode automatically

Manual mode:
- pass `--wait-manual`
- the script prints the Bolt11 invoice and continues polling for settlement
- if `qrencode` is installed, the invoice QR is rendered in the terminal
- default grace delay before polling continues: `30s` via `MANUAL_PAYMENT_GRACE_SECONDS`

## Safety

The script is host-local only:
- it calls only configured local service base URLs
- it does not accept arbitrary CLI URLs
- it never prints admin tokens or LNbits secrets

## Success

A successful run ends with:

```text
PASS: encrypted ingest + paid access smoke succeeded
```

The final lines print:
- `asset_id`
- playlist URL
- FAP key URL
