# Provider Announcement Contract

This document is the canonical contract for provider announcements between `audistro-provider` and `audistro-catalog`.

## Endpoint

- `POST /v1/providers/{providerId}/announce`

## Request body

```json
{
  "asset_id": "string",
  "transport": "https",
  "base_url": "https://.../assets/{assetId}",
  "priority": 10,
  "expires_in_seconds": 604800,
  "expires_at": 1700604800,
  "nonce": "hex",
  "signature": "128-char hex schnorr signature"
}
```

## Canonical message for signature

`provider_id|asset_id|transport|base_url|expires_at|nonce`

Rules:
- `provider_id` comes from the path segment `{providerId}`.
- `nonce` is lowercased before canonicalization.
- Message bytes are SHA-256 hashed.
- `signature` is Schnorr-over-secp256k1 over that hash.

## Validation rules (current code)

From `audistro-catalog` handler/service validation:
- `providerId` path must be non-empty.
- `asset_id` must be non-empty.
- `transport` must be exactly `https`.
- `base_url` must be valid URL with `https` scheme.
- `base_url` must include `/assets/{assetId}`.
- `base_url` length must be `<= 512` (handler precheck).
- `priority` must be in range `0..100`.
- `nonce` effective constraints: `16..128` chars, even-length hex.
- `signature` must be exactly `128` hex chars.
- `expires_at` is computed as:
  - request `expires_at`, or
  - `now + expires_in_seconds` if `expires_at` is zero.
- `expires_at` must be in the future.
- `expires_at` must be within max TTL (`CATALOG_MAX_ANNOUNCE_TTL_SECONDS`, default `1209600`).
- Nonce replay key is: `providerId|asset_id|lower(nonce)`.

## Responses

- `200`: `{"status":"ok"}`
- `400`: invalid request or signature
- `404`: provider or asset not found
- `409`: `{"error":"nonce_replay"}`
- `429`: asset provider limit reached
- `500`: internal error
