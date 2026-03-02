# Runbook: Incident Diagnosis

This runbook covers the current failure modes that already exist in the stack.

The source of truth for unfinished production work stays in [`docs/prod-todos.md`](./prod-todos.md).

## Payment Failures

Symptoms:
- `POST /v1/fap/challenge` succeeds but `/v1/fap/token` stays pending
- LNbits payment API returns `failed` or `insufficient balance`
- webhook retries do not settle the challenge

Check:
1. FAP logs around `challenge_id` and `payment_hash`
2. LNbits payment status for the `checking_id` or `payment_hash`
3. `FAP_WEBHOOK_SECRET` alignment between sender and FAP
4. paid-entry presence in `ledger_entries`

Likely causes:
- unpaid invoice
- webhook secret mismatch
- LNbits wallet lacks balance
- FAP cannot reach or interpret LNbits status

Immediate mitigation:
- verify invoice state directly in LNbits
- replay the webhook in a controlled way if the invoice is already paid
- do not rotate secrets during active diagnosis unless the mismatch is confirmed

## Key Gating Failures

Symptoms:
- `/hls/{assetId}/key` returns `401`, `403 device_mismatch`, or `payment_required`
- browser preflight passes playlist fetch but fails key fetch

Check:
1. device cookie presence
2. bearer token expiry and `challenge_id`
3. FAP logs for `/hls/{assetId}/key`
4. grant state for the asset and device
5. `FAP_PUBLIC_BASE_URL` and same-origin proxy configuration in web

Likely causes:
- missing or expired token
- device cookie mismatch
- grant never issued because settlement did not complete
- client using the wrong public base URL

Immediate mitigation:
- bootstrap a fresh device and repeat the challenge flow
- confirm token issuance before debugging hls.js behavior

## Ingest Failures

Symptoms:
- `ingest_jobs.status=failed`
- upload returns queued but never reaches published
- worker logs contain ffmpeg, publish, or announce errors

Check:
1. worker logs for the affected `job_id`
2. source file presence in `/var/lib/audistro-catalog/uploads/{assetId}`
3. build artifacts under `/var/lib/audistro-catalog/build/{assetId}`
4. `publish_report` or publish error fields on the job row
5. provider asset directories after publish

Likely causes:
- ffmpeg packaging failure
- FAP packaging-key fetch rejected
- provider internal rescan/announce rejected
- bad provider target mount configuration

Immediate mitigation:
- confirm the first configured provider target can be written and rescanned
- compare the worker env against `CATALOG_PROVIDER_TARGETS`

## Provider Announce Failures

Symptoms:
- asset files exist on provider volumes but Catalog playback returns no providers
- provider logs show `announce failed`

Check:
1. provider logs around `/internal/announce`
2. Catalog reachability from the provider container
3. provider `PROVIDER_CATALOG_BASE_URL`
4. Catalog asset existence for the announced `asset_id`
5. provider internal CIDR gating if announce is triggered remotely

Likely causes:
- provider can reach disk but not Catalog
- Catalog does not know the asset yet
- internal endpoint is reachable but announce payload is rejected

Immediate mitigation:
- rerun provider `rescan` and `announce` after verifying Catalog asset presence
- treat HTTP `200` from `/internal/announce` as insufficient unless the provider log confirms success

## Minimal Triage Bundle

Capture during an incident:
- relevant service logs
- the affected `asset_id`, `challenge_id`, `job_id`, or `payee_id`
- current env values for public/internal base URLs, without printing secrets
- output of:
  - `curl /healthz`
  - `curl /readyz`
  - relevant smoke or preflight step that reproduces the failure
