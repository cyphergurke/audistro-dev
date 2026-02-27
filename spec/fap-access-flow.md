# FAP Access Token + Device Grant Flow (P1)

This document describes the non-dev access flow used by the web player when `FAP_DEV_MODE=false`.

## 0) Bootstrap device (new)

Endpoint:

- `POST /v1/device/bootstrap`

Behavior:

- Creates (or refreshes) a pseudonymous device and sets cookie `fap_device_id`.
- Cookie attributes: `HttpOnly`, `SameSite=Lax`, `Path=/` (secure flag is env-configurable).

Response JSON (`200`):

```json
{
  "device_id": "dev_..."
}
```

## 1) Create challenge (invoice)

Endpoint:

- `POST /v1/fap/challenge`

Preferred request JSON (catalog-driven, no FAP asset seed required):

```json
{
  "asset_id": "asset2",
  "payee_id": "fap_payee_x",
  "amount_msat": 1000,
  "memo": "optional",
  "idempotency_key": "optional-string"
}
```

Legacy request JSON (still supported):

```json
{
  "asset_id": "asset2",
  "subject": "web:asset2"
}
```

Response JSON (`200`):

```json
{
  "challenge_id": "ch_...",
  "intent_id": "ch_...",
  "device_id": "dev_...",
  "asset_id": "asset2",
  "payee_id": "fap_payee_x",
  "status": "pending",
  "bolt11": "lnbc...",
  "payment_hash": "...",
  "checking_id": "...",
  "expires_at": 1773000000,
  "amount_msat": 1000,
  "resource_id": "hls:key:asset2"
}
```

Notes:

- `challenge_id` is the canonical id for token exchange.
- `intent_id` is returned for backward compatibility and equals `challenge_id` for catalog-driven mode.
- Challenge creation auto-bootstraps device cookie when missing.
- If `idempotency_key` is reused, the existing challenge is returned.

## 2) Settlement webhook

Endpoint:

- `POST /v1/fap/webhook/lnbits`

Behavior:

- Valid signature required via webhook secret.
- Maps LNbits payment (`checking_id` or `payment_hash`) to stored boosts and access challenges.
- Marks challenge `pending -> paid`.

## 3) Token exchange

Endpoint:

- `POST /v1/fap/token`

Request JSON:

```json
{
  "challenge_id": "ch_..."
}
```

Legacy request fields are still accepted:

```json
{
  "intent_id": "legacy_intent_id",
  "subject": "optional-legacy-subject"
}
```

Response JSON (`200`):

```json
{
  "token": "fap_access_token",
  "expires_at": 1773000600,
  "resource_id": "hls:key:asset2"
}
```

Non-success states:

- `409` + `payment not settled` while invoice is unpaid
- `409` + `intent expired` (legacy intent flow)
- `401` + `device_required` when challenge is device-bound and no device cookie is provided
- `403` + `device_mismatch` when token exchange cookie does not match the challenge device
- `403` on subject mismatch for repeated mint with different legacy subject

Idempotency:

- Repeating `POST /v1/fap/token` with the same `challenge_id` returns the same token while valid.
- If the previously minted token is expired and the challenge is still paid, FAP mints a new token for the same `(challenge_id, device_id)`.

## 4) Dev mode shortcut

When `FAP_DEV_MODE=true`, the web player may use:

- `POST /v1/access/{assetId}`

When `FAP_DEV_MODE=false`, this endpoint returns:

- `403 {"error":"dev_mode_disabled"}`

and the player must use the challenge/token flow above.

## 5) HLS key grant activation semantics (new)

Endpoint:

- `GET /hls/{assetId}/key`

Rules:

- Requires both:
  - access token (`Authorization: Bearer ...` or `?token=...`)
  - `fap_device_id` cookie
- Token must be valid for `hls:key:{assetId}` and token `sub` must equal cookie device id.
- Paid challenge creates an access grant (`active`, `valid_from=NULL`, `valid_until=NULL`).
- First successful key request activates time window:
  - `valid_from = now`
  - `valid_until = now + FAP_ACCESS_MINUTES_PER_PAYMENT * 60`
- After expiry:
  - grant transitions to `expired`
  - key endpoint returns `403 {"error":"grant_expired"}`
- If no grant exists:
  - key endpoint returns `403 {"error":"payment_required"}`

Read endpoint:

- `GET /v1/access/grants?asset_id=<optional>`
  - returns grants for current device cookie.
