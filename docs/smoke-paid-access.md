# Paid Access Smoke Test (M7e)

This smoke validates non-dev pay-per-access with LNbits:

1. create challenge (`POST /v1/fap/challenge`)
2. pay invoice (auto or manual)
3. settle via webhook
4. mint token (`POST /v1/fap/token`)
5. validate token against `GET /hls/{assetId}/key` (expects 16 bytes)

P1 note:

- the script now preserves `fap_device_id` cookie across challenge/token/key requests, matching device-bound grant rules.

During wait, the script also polls LNbits payment status (`GET /api/v1/payments/{checking_id|payment_hash}`) and triggers FAP webhook once paid is detected.

## Requirements

- running Docker compose stack
- LNbits wallet keys for invoice creation:
  - `FAP_LNBITS_INVOICE_API_KEY`
  - `FAP_LNBITS_READONLY_API_KEY`
  - optional aliases: `LNBITS_INVOICE_KEY`, `LNBITS_READ_KEY`
- automated mode additionally needs:
  - `LNBITS_PAYER_ADMIN_KEY` (payer wallet admin key)

You can provide secrets either as env vars or files:

- `FAP_LNBITS_INVOICE_API_KEY_FILE` (default: `secrets/FAP_LNBITS_INVOICE_API_KEY`)
- `FAP_LNBITS_READONLY_API_KEY_FILE` (default: `secrets/FAP_LNBITS_READONLY_API_KEY`)
- `LNBITS_INVOICE_KEY_FILE` (default: `secrets/lnbits_invoice_key`)
- `LNBITS_READ_KEY_FILE` (default: `secrets/lnbits_read_key`)
- `LNBITS_PAYER_ADMIN_KEY_FILE` (default: `secrets/lnbits_payer_admin_key`)

## Run (Automated)

```bash
FAP_LNBITS_INVOICE_API_KEY=... \
FAP_LNBITS_READONLY_API_KEY=... \
LNBITS_PAYER_ADMIN_KEY=... \
./scripts/smoke-paid-access.sh
```

## Run (Manual payment)

```bash
FAP_LNBITS_INVOICE_API_KEY=... \
FAP_LNBITS_READONLY_API_KEY=... \
./scripts/smoke-paid-access.sh --wait-manual
```

The script prints the `bolt11` invoice and waits for settlement.
If `qrencode` is installed, it also prints a terminal QR code.

## Useful overrides

- `ASSET_ID` (default: `asset_paid_smoke`)
- `FAP_PAYEE_ID` (optional override for challenge payee id)
- `AMOUNT_MSAT` (default: `1000000`)
- `LNBITS_BASE_URL` (default: `http://localhost:18090`)
- `WAIT_SECONDS` (default: `180`)
- `FORCE_WEBHOOK_ON_TIMEOUT` (default: `1`)
  - in `--wait-manual` mode, default becomes `0` unless explicitly set

## Notes

- The script seeds audistro-catalog artist/payee/asset automatically.
- It creates a FAP payee via `POST /v1/payees` and uses that ID in catalog mapping (`fap_payee_id`).
- If settlement is delayed, deterministic fallback posts a webhook event to FAP after a grace period.
- Optional ledger check (P4):
  - after token issuance, call `GET /v1/ledger` with the same `fap_device_id` cookie and verify there is a `paid` `access` entry for the challenge.
