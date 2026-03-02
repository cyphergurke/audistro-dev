#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CI_MODE="${CI:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-0}"

CATALOG_BASE_URL="${CATALOG_BASE_URL:-http://localhost:18080}"
FAP_BASE_URL="${FAP_BASE_URL:-http://localhost:18081}"
PROVIDER_BASE_URL="${PROVIDER_BASE_URL:-http://localhost:18082}"
FAP_PUBLIC_BASE_URL="${FAP_PUBLIC_BASE_URL:-http://localhost:18081}"
LNBITS_BASE_URL="${LNBITS_BASE_URL:-http://localhost:18090}"
LNBITS_BASE_URL_PAYEE="${LNBITS_BASE_URL_PAYEE:-http://lnbits:5000}"

ASSET_ID="${ASSET_ID:-asset_smoke_upload_encrypt_pay}"
ARTIST_ID="${ARTIST_ID:-ar_smoke_upload_encrypt_pay}"
ARTIST_HANDLE="${ARTIST_HANDLE:-smokeuploadencryptpay}"
DISPLAY_NAME="${DISPLAY_NAME:-Smoke Upload Encrypt Pay}"
CATALOG_PAYEE_ID="${CATALOG_PAYEE_ID:-pe_smoke_upload_encrypt_pay}"
FAP_PAYEE_ID="${FAP_PAYEE_ID:-}"
TITLE="${TITLE:-Smoke Upload Encrypt Pay}"
PRICE_MSAT="${PRICE_MSAT:-1000000}"
AMOUNT_MSAT="${AMOUNT_MSAT:-$PRICE_MSAT}"
SOURCE_AUDIO_FILE="${SOURCE_AUDIO_FILE:-}"
DURATION_SECONDS="${DURATION_SECONDS:-8}"
SINE_FREQUENCY="${SINE_FREQUENCY:-880}"
DEFAULT_WAIT_SECONDS=240
if [ "$CI_MODE" = "1" ]; then
  DEFAULT_WAIT_SECONDS=180
fi
WAIT_SECONDS="${WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-2}"
SETTLEMENT_GRACE_SECONDS="${SETTLEMENT_GRACE_SECONDS:-20}"
MANUAL_PAYMENT_GRACE_SECONDS="${MANUAL_PAYMENT_GRACE_SECONDS:-30}"
FORCE_WEBHOOK_ON_TIMEOUT_SET="${FORCE_WEBHOOK_ON_TIMEOUT+x}"
FORCE_WEBHOOK_ON_TIMEOUT="${FORCE_WEBHOOK_ON_TIMEOUT:-1}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/fap.cookies}"

MANUAL_WAIT=0
for arg in "$@"; do
  case "$arg" in
    --wait-manual)
      MANUAL_WAIT=1
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./scripts/smoke-upload-encrypt-pay.sh [--wait-manual]

This script proves, in one run:
  1. MP3 upload triggers ingest
  2. worker publishes encrypted HLS to provider
  3. playlist contains EXT-X-KEY AES-128 pointing to FAP public key URL
  4. paid-access flow issues an access token
  5. token + device cookie authorize GET /hls/{assetId}/key and return 16 bytes

Payment modes:
  - automated when LNBITS_PAYER_ADMIN_KEY is set
  - manual when --wait-manual is passed

Useful env overrides:
  CATALOG_BASE_URL
  FAP_BASE_URL
  PROVIDER_BASE_URL
  FAP_PUBLIC_BASE_URL
  LNBITS_BASE_URL
  LNBITS_BASE_URL_PAYEE
  CATALOG_ADMIN_TOKEN
  ASSET_ID
  ARTIST_ID
  ARTIST_HANDLE
  DISPLAY_NAME
  CATALOG_PAYEE_ID
  FAP_PAYEE_ID
  TITLE
  PRICE_MSAT
  AMOUNT_MSAT
  SOURCE_AUDIO_FILE
  WAIT_SECONDS
  WAIT_INTERVAL_SECONDS
  MANUAL_PAYMENT_GRACE_SECONDS
  LNBITS_INVOICE_KEY_PAYEE | LNBITS_INVOICE_KEY_PAYEE_FILE
  LNBITS_READ_KEY_PAYEE | LNBITS_READ_KEY_PAYEE_FILE
  LNBITS_PAYER_ADMIN_KEY | LNBITS_PAYER_ADMIN_KEY_FILE
USAGE
      exit 0
      ;;
    *)
      printf '[smoke-upload-encrypt-pay] FAIL: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[smoke-upload-encrypt-pay] %s\n' "$*"
}

fail() {
  printf '[smoke-upload-encrypt-pay] FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf '[smoke-upload-encrypt-pay] SKIP: %s\n' "$*"
  exit 0
}

print_invoice_qr() {
  local invoice="$1"
  if command -v qrencode >/dev/null 2>&1; then
    log "Invoice QR (terminal):"
    qrencode -t ANSIUTF8 "$invoice"
    return 0
  fi
  log "qrencode not installed; skipping terminal QR rendering"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

compose() {
  docker compose "$@"
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

read_secret_value() {
  local value_name="$1"
  local file_name="$2"
  local default_file="$3"
  local value="${!value_name:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  local file_path="${!file_name:-}"
  if [ -z "$file_path" ] && [ -n "$default_file" ]; then
    file_path="$default_file"
  fi
  if [ -n "$file_path" ] && [ -f "$file_path" ]; then
    tr -d '\r\n' <"$file_path"
    return 0
  fi
  printf ''
}

json_get() {
  local field="$1"
  local payload="$2"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r "$field"
    return 0
  fi

  JSON_FIELD="$field" JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os

field = os.environ["JSON_FIELD"]
payload = os.environ["JSON_PAYLOAD"]
obj = json.loads(payload)
if field.startswith('.'):
    field = field[1:]
value = obj
for part in [p for p in field.split('.') if p]:
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

curl_body_and_code() {
  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS "$@" -o "$out_file" -w '%{http_code}' || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"
  printf '%s\n%s\n' "$code" "$payload"
}

post_json() {
  local method="$1"
  local url="$2"
  local body="$3"
  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X "$method" -H 'Content-Type: application/json' -o "$out_file" -w '%{http_code}' "$url" -d "$body" || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"
  printf '%s\n%s\n' "$code" "$payload"
}

wait_http_ready() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while :; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    case "$code" in
      200|204|301|302|307|308)
        log "PASS: ${name} is ready"
        return 0
        ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "timeout waiting for ${name} at ${url} (last code=${code})"
    fi
    sleep 1
  done
}

validate_local_http_url() {
  local label="$1"
  local url="$2"
  URL_LABEL="$label" URL_VALUE="$url" python3 - <<'PY'
from urllib.parse import urlparse
import os
import sys

label = os.environ["URL_LABEL"]
value = os.environ["URL_VALUE"].strip()
parsed = urlparse(value)
if parsed.scheme not in ("http", "https"):
    sys.stderr.write(f"invalid {label}: scheme must be http or https\n")
    sys.exit(1)
if parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
    sys.stderr.write(f"invalid {label}: host must be local for smoke safety\n")
    sys.exit(1)
PY
}

validate_allowed_service_url() {
  local label="$1"
  local url="$2"
  URL_LABEL="$label" URL_VALUE="$url" python3 - <<'PY'
from urllib.parse import urlparse
import os
import sys

label = os.environ["URL_LABEL"]
value = os.environ["URL_VALUE"].strip()
parsed = urlparse(value)
if parsed.scheme not in ("http", "https"):
    sys.stderr.write(f"invalid {label}: scheme must be http or https\n")
    sys.exit(1)
if parsed.hostname not in ("localhost", "127.0.0.1", "::1", "lnbits", "host.docker.internal"):
    sys.stderr.write(f"invalid {label}: host not allowlisted\n")
    sys.exit(1)
PY
}

pay_invoice_auto() {
  local bolt11="$1"
  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Api-Key: ${LNBITS_PAYER_ADMIN_KEY}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${LNBITS_BASE_URL%/}/api/v1/payments" \
    -d "{\"out\":true,\"bolt11\":\"${bolt11}\"}" || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"

  case "$code" in
    200|201|202)
      log "PASS: LNbits pay API accepted invoice"
      return 0
      ;;
    *)
      log "Auto-pay failed (code=${code}); falling back to manual payment wait"
      return 1
      ;;
  esac
}

lnbits_check_payment_paid() {
  local payment_ref="$1"
  [ -n "$payment_ref" ] || return 1
  [ "$payment_ref" != "null" ] || return 1

  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X GET \
    -H "X-Api-Key: ${LNBITS_READ_KEY_PAYEE}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${LNBITS_BASE_URL%/}/api/v1/payments/${payment_ref}" || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"

  [ "$code" = "200" ] || return 1

  local paid pending status
  paid="$(json_get '.paid' "$payload" || true)"
  pending="$(json_get '.pending' "$payload" || true)"
  status="$(json_get '.status' "$payload" || true)"
  paid="$(printf '%s' "$paid" | tr '[:upper:]' '[:lower:]')"
  pending="$(printf '%s' "$pending" | tr '[:upper:]' '[:lower:]')"
  status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"

  [ "$paid" = "true" ] && return 0
  [ "$pending" = "false" ] && [ -n "$pending" ] && [ "$pending" != "null" ] && return 0
  case "$status" in
    paid|complete|completed|settled)
      return 0
      ;;
  esac
  return 1
}

trigger_settlement_webhook() {
  local checking_id="$1"
  local payment_hash="$2"
  [ -n "$FAP_WEBHOOK_SECRET" ] || fail "FAP_WEBHOOK_SECRET missing; cannot trigger settlement webhook fallback"

  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-FAP-Webhook-Secret: ${FAP_WEBHOOK_SECRET}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${FAP_BASE_URL%/}/v1/fap/webhook/lnbits" \
    -d "{\"checking_id\":\"${checking_id}\",\"payment_hash\":\"${payment_hash}\",\"paid\":true}" || true)"
  rm -f "$out_file"
  case "$code" in
    200|204)
      log "PASS: settlement webhook fallback accepted"
      ;;
    *)
      fail "deterministic webhook fallback failed (code=${code})"
      ;;
  esac
}

generate_mp3_fixture() {
  local output_path="$1"

  if [ -n "$SOURCE_AUDIO_FILE" ]; then
    [ -f "$SOURCE_AUDIO_FILE" ] || fail "SOURCE_AUDIO_FILE does not exist: $SOURCE_AUDIO_FILE"
    cp "$SOURCE_AUDIO_FILE" "$output_path"
    return 0
  fi

  local catalog_image
  catalog_image="$(docker compose images -q audistro-catalog 2>/dev/null | head -n1)"
  [ -n "$catalog_image" ] || fail "could not resolve audistro-catalog image id for fixture generation"

  local out_dir
  out_dir="$(dirname "$output_path")"
  docker run --rm \
    -v "${out_dir}:/out" \
    "$catalog_image" \
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "sine=frequency=${SINE_FREQUENCY}:duration=${DURATION_SECONDS}:sample_rate=44100" \
      -c:a libmp3lame -b:a 128k "/out/$(basename "$output_path")" >/dev/null
}

need_cmd docker
need_cmd curl
need_cmd python3
[ "$WAIT_SECONDS" -gt 0 ] || fail "WAIT_SECONDS must be > 0"
[ "$WAIT_INTERVAL_SECONDS" -gt 0 ] || fail "WAIT_INTERVAL_SECONDS must be > 0"
[ "$MANUAL_PAYMENT_GRACE_SECONDS" -ge 0 ] || fail "MANUAL_PAYMENT_GRACE_SECONDS must be >= 0"
[ "$PRICE_MSAT" -gt 0 ] || fail "PRICE_MSAT must be > 0"
[ "$AMOUNT_MSAT" -gt 0 ] || fail "AMOUNT_MSAT must be > 0"

validate_local_http_url CATALOG_BASE_URL "$CATALOG_BASE_URL"
validate_local_http_url FAP_BASE_URL "$FAP_BASE_URL"
validate_local_http_url PROVIDER_BASE_URL "$PROVIDER_BASE_URL"
validate_local_http_url FAP_PUBLIC_BASE_URL "$FAP_PUBLIC_BASE_URL"
validate_local_http_url LNBITS_BASE_URL "$LNBITS_BASE_URL"
validate_allowed_service_url LNBITS_BASE_URL_PAYEE "$LNBITS_BASE_URL_PAYEE"

CATALOG_ADMIN_TOKEN="${CATALOG_ADMIN_TOKEN:-$(read_env_file_value "${ROOT_DIR}/env/audistro-catalog.env" "CATALOG_ADMIN_TOKEN")}"
FAP_WEBHOOK_SECRET="${FAP_WEBHOOK_SECRET:-$(read_env_file_value "${ROOT_DIR}/env/fap.env" "FAP_WEBHOOK_SECRET")}"
LNBITS_INVOICE_KEY_PAYEE="$(read_secret_value LNBITS_INVOICE_KEY_PAYEE LNBITS_INVOICE_KEY_PAYEE_FILE "${ROOT_DIR}/secrets/lnbits_invoice_key")"
LNBITS_READ_KEY_PAYEE="$(read_secret_value LNBITS_READ_KEY_PAYEE LNBITS_READ_KEY_PAYEE_FILE "${ROOT_DIR}/secrets/lnbits_read_key")"
LNBITS_PAYER_ADMIN_KEY="$(read_secret_value LNBITS_PAYER_ADMIN_KEY LNBITS_PAYER_ADMIN_KEY_FILE "${ROOT_DIR}/secrets/lnbits_payer_admin_key")"

if [ -z "$LNBITS_INVOICE_KEY_PAYEE" ]; then
  LNBITS_INVOICE_KEY_PAYEE="${LNBITS_INVOICE_KEY:-${FAP_LNBITS_INVOICE_API_KEY:-$(read_env_file_value "${ROOT_DIR}/env/fap.env" "FAP_LNBITS_INVOICE_API_KEY")}}"
fi
if [ -z "$LNBITS_READ_KEY_PAYEE" ]; then
  LNBITS_READ_KEY_PAYEE="${LNBITS_READ_KEY:-${FAP_LNBITS_READONLY_API_KEY:-$(read_env_file_value "${ROOT_DIR}/env/fap.env" "FAP_LNBITS_READONLY_API_KEY")}}"
fi

[ -n "$CATALOG_ADMIN_TOKEN" ] || fail "CATALOG_ADMIN_TOKEN is required"
if [ "$MANUAL_WAIT" -eq 0 ] && [ -z "$LNBITS_PAYER_ADMIN_KEY" ]; then
  if [ "$SKIP_MANUAL" = "1" ]; then
    skip "LNBITS_PAYER_ADMIN_KEY missing and SKIP_MANUAL=1"
  fi
  fail "LNBITS_PAYER_ADMIN_KEY missing; set it for automated payment or rerun with --wait-manual"
fi
if [ "$MANUAL_WAIT" -eq 1 ] && [ -z "$FORCE_WEBHOOK_ON_TIMEOUT_SET" ]; then
  FORCE_WEBHOOK_ON_TIMEOUT=0
fi

work_dir="$(mktemp -d)"
upload_audio_path="${work_dir}/source.mp3"
cleanup() {
  rm -rf "$work_dir"
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT
rm -f "$COOKIE_JAR"

log "Starting compose stack"
compose up -d --build

wait_http_ready "audistro-catalog /healthz" "${CATALOG_BASE_URL%/}/healthz"
wait_http_ready "audistro-fap /healthz" "${FAP_BASE_URL%/}/healthz"
wait_http_ready "audistro-provider /readyz" "${PROVIDER_BASE_URL%/}/readyz"
wait_http_ready "lnbits /" "${LNBITS_BASE_URL%/}/"

bootstrap_artist_id="$ARTIST_ID"
bootstrap_catalog_payee_id="$CATALOG_PAYEE_ID"
bootstrap_fap_payee_id=""

log "Checking existing catalog payee mapping"
mapfile -t payee_lookup_result < <(curl_body_and_code "${CATALOG_BASE_URL%/}/v1/payees/${CATALOG_PAYEE_ID}")
payee_lookup_code="${payee_lookup_result[0]}"
payee_lookup_body="${payee_lookup_result[1]}"
if [ "$payee_lookup_code" = "200" ]; then
  bootstrap_artist_id="$(json_get '.payee.artist_id' "$payee_lookup_body")"
  bootstrap_catalog_payee_id="$(json_get '.payee.payee_id' "$payee_lookup_body")"
  bootstrap_fap_payee_id="$(json_get '.payee.fap_payee_id' "$payee_lookup_body")"
  [ -n "$bootstrap_artist_id" ] && [ "$bootstrap_artist_id" != "null" ] || fail "existing catalog payee missing artist_id"
  [ -n "$bootstrap_fap_payee_id" ] && [ "$bootstrap_fap_payee_id" != "null" ] || fail "existing catalog payee missing fap_payee_id"
  log "PASS: reusing existing catalog mapping payee_id=${bootstrap_catalog_payee_id}"
elif [ "$payee_lookup_code" = "404" ]; then
  if [ -n "$FAP_PAYEE_ID" ]; then
    bootstrap_fap_payee_id="$FAP_PAYEE_ID"
    log "Using provided FAP_PAYEE_ID for catalog mapping"
  elif [ -n "$LNBITS_INVOICE_KEY_PAYEE" ] && [ -n "$LNBITS_READ_KEY_PAYEE" ]; then
    log "Creating FAP payee"
    fap_payee_payload="$(cat <<JSON
{"display_name":"${DISPLAY_NAME}","lnbits_base_url":"${LNBITS_BASE_URL_PAYEE}","lnbits_invoice_key":"${LNBITS_INVOICE_KEY_PAYEE}","lnbits_read_key":"${LNBITS_READ_KEY_PAYEE}"}
JSON
)"
    mapfile -t fap_payee_create_result < <(post_json POST "${FAP_BASE_URL%/}/v1/payees" "$fap_payee_payload")
    fap_payee_create_code="${fap_payee_create_result[0]}"
    fap_payee_create_body="${fap_payee_create_result[1]}"
    [ "$fap_payee_create_code" = "200" ] || fail "POST /v1/payees failed (code=${fap_payee_create_code}): ${fap_payee_create_body}"
    bootstrap_fap_payee_id="$(json_get '.payee_id' "$fap_payee_create_body")"
    [ -n "$bootstrap_fap_payee_id" ] && [ "$bootstrap_fap_payee_id" != "null" ] || fail "missing payee_id in FAP create response"
    log "PASS: created FAP payee"
  else
    fail "no existing mapping and no payee credentials available; set LNBITS_INVOICE_KEY_PAYEE/LNBITS_READ_KEY_PAYEE or FAP_PAYEE_ID"
  fi

  log "Creating catalog artist/payee mapping"
  catalog_bootstrap_payload="$(cat <<JSON
{"artist_id":"${ARTIST_ID}","handle":"${ARTIST_HANDLE}","display_name":"${DISPLAY_NAME}","payee":{"payee_id":"${CATALOG_PAYEE_ID}","fap_public_base_url":"${FAP_PUBLIC_BASE_URL}","fap_payee_id":"${bootstrap_fap_payee_id}"}}
JSON
)"
  bootstrap_resp_file="$(mktemp)"
  bootstrap_code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Admin-Token: ${CATALOG_ADMIN_TOKEN}" \
    -o "$bootstrap_resp_file" \
    -w '%{http_code}' \
    "${CATALOG_BASE_URL%/}/v1/admin/bootstrap/artist" \
    -d "$catalog_bootstrap_payload" || true)"
  bootstrap_body="$(cat "$bootstrap_resp_file")"
  rm -f "$bootstrap_resp_file"
  [ "$bootstrap_code" = "200" ] || fail "catalog bootstrap failed (code=${bootstrap_code}): ${bootstrap_body}"
  bootstrap_artist_id="$(json_get '.artist_id' "$bootstrap_body")"
  bootstrap_catalog_payee_id="$(json_get '.payee_id' "$bootstrap_body")"
  returned_fap_payee_id="$(json_get '.fap_payee_id' "$bootstrap_body")"
  [ "$returned_fap_payee_id" = "$bootstrap_fap_payee_id" ] || fail "catalog bootstrap returned unexpected fap_payee_id"
  log "PASS: created catalog artist/payee mapping"
else
  fail "GET /v1/payees/${CATALOG_PAYEE_ID} failed (code=${payee_lookup_code}): ${payee_lookup_body}"
fi

log "Preparing MP3 fixture"
generate_mp3_fixture "$upload_audio_path"
[ -s "$upload_audio_path" ] || fail "generated upload fixture is empty"

log "Uploading MP3 via catalog admin endpoint"
upload_resp_file="$(mktemp)"
upload_code="$(curl -sS -X POST \
  -H "X-Admin-Token: ${CATALOG_ADMIN_TOKEN}" \
  -o "$upload_resp_file" \
  -w '%{http_code}' \
  -F "artist_id=${bootstrap_artist_id}" \
  -F "payee_id=${bootstrap_catalog_payee_id}" \
  -F "title=${TITLE}" \
  -F "price_msat=${PRICE_MSAT}" \
  -F "asset_id=${ASSET_ID}" \
  -F "audio=@${upload_audio_path};type=audio/mpeg;filename=$(basename "$upload_audio_path")" \
  "${CATALOG_BASE_URL%/}/v1/admin/assets/upload" || true)"
upload_body="$(cat "$upload_resp_file")"
rm -f "$upload_resp_file"
[ "$upload_code" = "202" ] || fail "upload failed (code=${upload_code}): ${upload_body}"
job_id="$(json_get '.job_id' "$upload_body")"
upload_asset_id="$(json_get '.asset_id' "$upload_body")"
[ "$upload_asset_id" = "$ASSET_ID" ] || fail "unexpected upload asset_id=${upload_asset_id}"
[ -n "$job_id" ] && [ "$job_id" != "null" ] || fail "missing job_id in upload response"

log "Waiting for ingest job publication"
published=0
deadline=$((SECONDS + WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  job_resp_file="$(mktemp)"
  job_code="$(curl -sS -H "X-Admin-Token: ${CATALOG_ADMIN_TOKEN}" -o "$job_resp_file" -w '%{http_code}' "${CATALOG_BASE_URL%/}/v1/admin/ingest/jobs/${job_id}" || true)"
  job_body="$(cat "$job_resp_file")"
  rm -f "$job_resp_file"
  [ "$job_code" = "200" ] || fail "ingest job poll failed (code=${job_code}): ${job_body}"
  job_status="$(json_get '.status' "$job_body")"
  case "$job_status" in
    published)
      published=1
      break
      ;;
    failed)
      fail "ingest job failed: $(json_get '.error' "$job_body")"
      ;;
  esac
  sleep "$WAIT_INTERVAL_SECONDS"
done
[ "$published" = "1" ] || fail "timed out waiting for ingest job=${job_id} to publish"
log "PASS: ingest job published"

log "Validating encrypted playlist and first segment"
playlist_url="${PROVIDER_BASE_URL%/}/assets/${ASSET_ID}/master.m3u8"
playlist_payload="$(curl -fsS "$playlist_url")"
expected_key_uri="${FAP_PUBLIC_BASE_URL%/}/hls/${ASSET_ID}/key"
printf '%s\n' "$playlist_payload" | grep -q '#EXT-X-KEY:METHOD=AES-128' || fail "playlist missing AES-128 key line"
printf '%s\n' "$playlist_payload" | grep -q "URI=\"${expected_key_uri}\"" || fail "playlist missing expected key URI ${expected_key_uri}"
first_segment="$(printf '%s\n' "$playlist_payload" | awk 'substr($0,1,1)!="#" && $0 ~ /\.(ts|m4s)(\?.*)?$/ {print; exit}')"
[ -n "$first_segment" ] || fail "playlist missing media segment entries"
segment_code="$(curl -sS -o /dev/null -w '%{http_code}' "${PROVIDER_BASE_URL%/}/assets/${ASSET_ID}/${first_segment}" || true)"
[ "$segment_code" = "200" ] || fail "provider segment fetch failed (code=${segment_code})"
log "PASS: encrypted playlist and segment fetch validated"

log "Loading playback pay hints"
mapfile -t playback_result < <(curl_body_and_code "${CATALOG_BASE_URL%/}/v1/playback/${ASSET_ID}")
playback_code="${playback_result[0]}"
playback_body="${playback_result[1]}"
[ "$playback_code" = "200" ] || fail "GET /v1/playback/${ASSET_ID} failed (code=${playback_code}): ${playback_body}"
challenge_payee_id="$(json_get '.asset.pay.fap_payee_id' "$playback_body")"
challenge_fap_url="$(json_get '.asset.pay.fap_url' "$playback_body")"
[ -n "$challenge_payee_id" ] && [ "$challenge_payee_id" != "null" ] || fail "playback missing asset.pay.fap_payee_id"
[ -n "$challenge_fap_url" ] && [ "$challenge_fap_url" != "null" ] || fail "playback missing asset.pay.fap_url"
[ "$challenge_fap_url" = "$FAP_PUBLIC_BASE_URL" ] || fail "playback returned unexpected fap_url=${challenge_fap_url}"

log "Bootstrapping FAP device cookie"
device_bootstrap_resp="$(mktemp)"
device_bootstrap_code="$(curl -sS -X POST -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o "$device_bootstrap_resp" -w '%{http_code}' "${FAP_BASE_URL%/}/v1/device/bootstrap" || true)"
rm -f "$device_bootstrap_resp"
[ "$device_bootstrap_code" = "200" ] || fail "POST /v1/device/bootstrap failed (code=${device_bootstrap_code})"
grep -q 'fap_device_id' "$COOKIE_JAR" || fail "device bootstrap did not set fap_device_id cookie"

idempotency_key="smoke-$(date +%s)-$RANDOM"
challenge_payload="$(cat <<JSON
{"asset_id":"${ASSET_ID}","payee_id":"${challenge_payee_id}","amount_msat":${AMOUNT_MSAT},"idempotency_key":"${idempotency_key}"}
JSON
)"
log "Creating paid-access challenge"
challenge_resp_file="$(mktemp)"
challenge_code="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -c "$COOKIE_JAR" \
  -b "$COOKIE_JAR" \
  -o "$challenge_resp_file" \
  -w '%{http_code}' \
  "${FAP_BASE_URL%/}/v1/fap/challenge" \
  -d "$challenge_payload" || true)"
challenge_body="$(cat "$challenge_resp_file")"
rm -f "$challenge_resp_file"
[ "$challenge_code" = "200" ] || fail "POST /v1/fap/challenge failed (code=${challenge_code}): ${challenge_body}"
challenge_id="$(json_get '.challenge_id' "$challenge_body")"
bolt11="$(json_get '.bolt11' "$challenge_body")"
checking_id="$(json_get '.checking_id' "$challenge_body")"
payment_hash="$(json_get '.payment_hash' "$challenge_body")"
[ -n "$challenge_id" ] && [ "$challenge_id" != "null" ] || fail "challenge response missing challenge_id"
[ -n "$bolt11" ] && [ "$bolt11" != "null" ] || fail "challenge response missing bolt11"

if [ "$MANUAL_WAIT" -eq 1 ]; then
  log "Manual payment mode. Pay this invoice and keep the script running:"
  printf '%s\n' "$bolt11"
  print_invoice_qr "$bolt11"
  if [ "$MANUAL_PAYMENT_GRACE_SECONDS" -gt 0 ]; then
    log "Waiting ${MANUAL_PAYMENT_GRACE_SECONDS}s before token polling continues"
    sleep "$MANUAL_PAYMENT_GRACE_SECONDS"
  fi
else
  log "Paying invoice via LNbits payer wallet"
  if ! pay_invoice_auto "$bolt11"; then
    log "Manual fallback. Pay this invoice and keep the script running:"
    printf '%s\n' "$bolt11"
    print_invoice_qr "$bolt11"
    if [ "$MANUAL_PAYMENT_GRACE_SECONDS" -gt 0 ]; then
      log "Waiting ${MANUAL_PAYMENT_GRACE_SECONDS}s before token polling continues"
      sleep "$MANUAL_PAYMENT_GRACE_SECONDS"
    fi
  fi
fi

log "Polling token exchange"
token=""
webhook_fallback_done=0
token_started_at="$SECONDS"
poll_count=0
deadline=$((SECONDS + WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  poll_count=$((poll_count + 1))
  token_resp_file="$(mktemp)"
  token_code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -o "$token_resp_file" \
    -w '%{http_code}' \
    "${FAP_BASE_URL%/}/v1/fap/token" \
    -d "{\"challenge_id\":\"${challenge_id}\"}" || true)"
  token_body="$(cat "$token_resp_file")"
  rm -f "$token_resp_file"

  if [ "$token_code" = "200" ]; then
    token="$(json_get '.token' "$token_body")"
    [ -n "$token" ] && [ "$token" != "null" ] || fail "token missing in /v1/fap/token success response"
    log "PASS: access token issued"
    break
  fi
  [ "$token_code" = "409" ] || fail "POST /v1/fap/token unexpected code=${token_code}: ${token_body}"

  if [ "$poll_count" -eq 1 ] || [ $((poll_count % 5)) -eq 0 ]; then
    log "pending: token not issued yet after $((SECONDS - token_started_at))s"
  fi

  if [ "$webhook_fallback_done" -eq 0 ] && [ -n "$LNBITS_READ_KEY_PAYEE" ]; then
    if lnbits_check_payment_paid "$checking_id" || lnbits_check_payment_paid "$payment_hash"; then
      log "LNbits reports invoice as paid; notifying FAP webhook"
      trigger_settlement_webhook "$checking_id" "$payment_hash"
      webhook_fallback_done=1
      sleep 1
      continue
    fi
  fi

  if [ "$FORCE_WEBHOOK_ON_TIMEOUT" = "1" ] \
    && [ "$webhook_fallback_done" -eq 0 ] \
    && [ $((SECONDS - token_started_at)) -ge "$SETTLEMENT_GRACE_SECONDS" ] \
    && { [ -n "$checking_id" ] && [ "$checking_id" != "null" ] || [ -n "$payment_hash" ] && [ "$payment_hash" != "null" ]; }; then
    log "No settlement observed yet; triggering deterministic webhook fallback"
    trigger_settlement_webhook "$checking_id" "$payment_hash"
    webhook_fallback_done=1
  fi

  sleep "$WAIT_INTERVAL_SECONDS"
done
[ -n "$token" ] || fail "timed out waiting for access token"

log "Validating authorized key fetch"
key_path="${work_dir}/asset.key"
key_code="$(curl -sS -o "$key_path" -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  -b "$COOKIE_JAR" \
  "${FAP_BASE_URL%/}/hls/${ASSET_ID}/key" || true)"
[ "$key_code" = "200" ] || fail "GET /hls/${ASSET_ID}/key expected 200, got ${key_code}"
key_len="$(wc -c < "$key_path" | tr -d '[:space:]')"
[ "$key_len" = "16" ] || fail "expected 16-byte AES key, got ${key_len}"

log "PASS: encrypted ingest + paid access smoke succeeded"
log "asset_id=${ASSET_ID}"
log "playlist=${PROVIDER_BASE_URL%/}/assets/${ASSET_ID}/master.m3u8"
log "key_url=${FAP_PUBLIC_BASE_URL%/}/hls/${ASSET_ID}/key"
