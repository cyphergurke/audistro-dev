# Origin HMAC Contract

This document captures the HMAC request-signing format in `audistro-provider/internal/originauth/hmac.go`.

## Headers

`audistro-provider` sets these request headers:
- `X-AudistroProvider-KeyId`
- `X-AudistroProvider-Timestamp`
- `X-AudistroProvider-Nonce`
- `X-AudistroProvider-Signature`
- `X-AudistroProvider-ProviderId`

## Canonical string

Canonical string format:

`METHOD + "\\n" + PATH_WITH_OPTIONAL_QUERY + "\\n" + UNIX_TS + "\\n" + NONCE_HEX + "\\n" + PROVIDER_ID`

Rules from current implementation:
- Allowed methods: `GET`, `HEAD`.
- `PATH_WITH_OPTIONAL_QUERY` starts from `req.URL.EscapedPath()`.
- If escaped path is empty, it becomes `/`.
- If `include_query=true` and raw query exists, append `?` + raw query.
- Nonce is 16 random bytes, lowercase hex in header and canonical string.
- Signature is `hex(hmac_sha256(secret, canonical_string))`.

## Notes

- HMAC signing is only active when origin auth mode is HMAC.
- Secret should be read from `PROVIDER_ORIGIN_HMAC_SECRET_PATH`.
