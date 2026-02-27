# LNbits Dev Setup

This stack now includes LNbits as a local dev service.

## Start

From repo root:

```bash
docker compose up -d lnbits
```

UI URL:

- `http://localhost:18090`

## Wallet Setup In LNbits UI

1. Open `http://localhost:18090`.
2. Create a wallet in the LNbits UI.
3. Open wallet/API settings and copy:
   - Admin key
   - Invoice (read) key

These keys are what downstream integrations (like FAP payee setup) will use.

## Webhook Wiring To FAP

When configuring webhook notifications in LNbits (or your chosen backend flow), use:

- Webhook URL (compose network): `http://audistro-fap:8080/v1/fap/webhook/lnbits`
- Webhook secret: must match `FAP_WEBHOOK_SECRET` from `env/fap.env`

## Funding Source Note (Important)

Default `env/lnbits.env` uses:

- `LNBITS_BACKEND_WALLET_CLASS=OpenNodeWallet`

This is useful for UI/API bootstrapping but does not provide a real funded Lightning backend.
Invoices may be generated but not actually payable until you configure a real backend wallet/funding source.

For OpenNode-style setup:

- put credentials in `secrets/opennode_key` and `secrets/opennode_secret`
- update `env/lnbits.env` backend wallet settings to match the backend class supported by your LNbits version

## Quick Health Check

```bash
./scripts/test-lnbits.sh
```

## M7 Boost Flow (Real Invoice, Non-Dev)

When `FAP_DEV_MODE=false`, `POST /v1/boost` creates a real LNbits invoice using the payee wallet keys stored in FAP.

### 1) Seed a payee in FAP with LNbits keys

```bash
curl -sS -X POST http://localhost:18081/v1/payees \
  -H 'content-type: application/json' \
  -d '{
    "display_name":"Artist LNbits",
    "lnbits_base_url":"http://lnbits:5000",
    "FAP_LNBITS_INVOICE_API_KEY":"<FAP_LNBITS_INVOICE_API_KEY>",
    "FAP_LNBITS_READONLY_API_KEY":"<FAP_LNBITS_READONLY_API_KEY>"
  }'
```

### 2) Create a boost invoice

```bash
curl -sS -X POST http://localhost:18081/v1/boost \
  -H 'content-type: application/json' \
  -d '{
    "asset_id":"asset1",
    "payee_id":"<FAP_PAYEE_ID>",
    "amount_msat":1000000,
    "idempotency_key":"boost-local-001"
  }'
```

### 3) Webhook target

LNbits webhook target should stay:

- `http://audistro-fap:8080/v1/fap/webhook/lnbits`

Webhook secret must match `FAP_WEBHOOK_SECRET`.

Once invoice is paid, webhook updates boost status to `paid`.
