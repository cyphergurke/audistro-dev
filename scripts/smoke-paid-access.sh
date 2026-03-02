#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CI_MODE="${CI:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-0}"

ASSET_ID="${ASSET_ID:-asset_paid_smoke}"
ARTIST_ID="${ARTIST_ID:-artist_paid_smoke}"
ARTIST_HANDLE="${ARTIST_HANDLE:-paidsmoke}"
CATALOG_PAYEE_ID="${CATALOG_PAYEE_ID:-payee_paid_smoke}"
AMOUNT_MSAT="${AMOUNT_MSAT:-1000000}"
DEFAULT_WAIT_SECONDS=180
if [ "$CI_MODE" = "1" ]; then
  DEFAULT_WAIT_SECONDS=120
fi
WAIT_SECONDS="${WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-2}"
SETTLEMENT_GRACE_SECONDS="${SETTLEMENT_GRACE_SECONDS:-20}"
FORCE_WEBHOOK_ON_TIMEOUT_SET="${FORCE_WEBHOOK_ON_TIMEOUT+x}"
FORCE_WEBHOOK_ON_TIMEOUT="${FORCE_WEBHOOK_ON_TIMEOUT:-1}"

CATALOG_URL="${CATALOG_URL:-http://localhost:18080}"
FAP_URL="${FAP_URL:-http://localhost:18081}"
LNBITS_BASE_URL="${LNBITS_BASE_URL:-http://localhost:18090}"
FAP_LNBITS_BASE_URL="${FAP_LNBITS_BASE_URL:-http://lnbits:5000}"
FAP_PUBLIC_BASE_URL="${FAP_PUBLIC_BASE_URL:-http://localhost:18081}"

MANUAL_WAIT=0
for arg in "$@"; do
  case "$arg" in
    --wait-manual)
      MANUAL_WAIT=1
      ;;
    --help|-h)
      cat <<'EOF'
Usage: ./scripts/smoke-paid-access.sh [--wait-manual]

Env overrides:
  ASSET_ID
  FAP_PAYEE_ID (optional; defaults to created FAP payee id)
  AMOUNT_MSAT
  LNBITS_BASE_URL
  LNBITS_PAYER_ADMIN_KEY (required for automated pay mode)
  LNBITS_PAYER_ADMIN_KEY_FILE
  FAP_LNBITS_INVOICE_API_KEY (required)
  FAP_LNBITS_INVOICE_API_KEY_FILE
  FAP_LNBITS_READONLY_API_KEY (required)
  FAP_LNBITS_READONLY_API_KEY_FILE
  WAIT_SECONDS
EOF
      exit 0
      ;;
    *)
      printf '[smoke-paid-access] FAIL: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[smoke-paid-access] %s\n' "$*"
}

fail() {
  printf '[smoke-paid-access] FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf '[smoke-paid-access] SKIP: %s\n' "$*"
  exit 0
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
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

print_invoice_qr() {
  local invoice="$1"
  if command -v qrencode >/dev/null 2>&1; then
    log "Invoice QR (terminal):"
    qrencode -t ANSIUTF8 "$invoice"
    return 0
  fi
  log "qrencode not installed; skipping terminal QR rendering"
}

lnbits_check_payment_paid() {
  local payment_ref="$1"
  [ -n "$payment_ref" ] || return 1
  [ "$payment_ref" != "null" ] || return 1

  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X GET \
    -H "X-Api-Key: ${LNBITS_READ_KEY}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${LNBITS_BASE_URL%/}/api/v1/payments/${payment_ref}" || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"

  if [ "$code" != "200" ]; then
    return 1
  fi

  local paid pending status
  paid="$(json_get '.paid' "$payload" || true)"
  pending="$(json_get '.pending' "$payload" || true)"
  status="$(json_get '.status' "$payload" || true)"
  paid="$(printf '%s' "$paid" | tr '[:upper:]' '[:lower:]')"
  pending="$(printf '%s' "$pending" | tr '[:upper:]' '[:lower:]')"
  status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"

  if [ "$paid" = "true" ]; then
    return 0
  fi
  if [ "$pending" = "false" ] && [ -n "$pending" ] && [ "$pending" != "null" ]; then
    return 0
  fi
  if [ "$status" = "paid" ] || [ "$status" = "complete" ] || [ "$status" = "completed" ] || [ "$status" = "settled" ]; then
    return 0
  fi
  return 1
}

json_get() {
  local field="$1"
  local payload="$2"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r "$field"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_FIELD="$field" JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os

field = os.environ["JSON_FIELD"]
payload = os.environ["JSON_PAYLOAD"]
obj = json.loads(payload)

if field.startswith("."):
    field = field[1:]
parts = [p for p in field.split(".") if p]
value = obj
for part in parts:
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
    return 0
  fi

  fail "jq or python3 is required to parse JSON"
}

wait_http_200() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))

  while :; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    if [ "$code" = "200" ]; then
      log "PASS: ${name} is ready"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "timeout waiting for ${name} at ${url} (last code=${code})"
    fi
    sleep 1
  done
}

service_cid() {
  local service="$1"
  local cid
  cid="$(compose ps -q "$service" | head -n1)"
  if [ -z "$cid" ]; then
    fail "container not found for service: $service"
  fi
  printf '%s' "$cid"
}

exec_in() {
  local cid="$1"
  shift
  docker exec -i "$cid" sh -lc "$*"
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

catalog_sql() {
  local sql="$1"
  exec_in "$CATALOG_CID" "sqlite3 \"$AUDICATALOG_DB_PATH\" \"$sql\""
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

pay_invoice_auto() {
  local bolt11="$1"
  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X POST \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${LNBITS_PAYER_ADMIN_KEY}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${LNBITS_BASE_URL%/}/api/v1/payments" \
    -d "{\"out\":true,\"bolt11\":\"${bolt11}\"}" || true)"
  local payload
  payload="$(cat "$out_file")"
  rm -f "$out_file"

  if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "202" ]; then
    fail "LNbits auto-pay failed (code=${code}): ${payload}"
  fi
  log "PASS: LNbits pay API accepted invoice (code=${code})"
}

trigger_settlement_webhook() {
  local checking_id="$1"
  local payment_hash="$2"
  if [ -z "$FAP_WEBHOOK_SECRET" ]; then
    fail "FAP_WEBHOOK_SECRET missing; cannot trigger deterministic settlement webhook fallback"
  fi
  local out_file
  out_file="$(mktemp)"
  local code
  code="$(curl -sS -X POST \
    -H "Content-Type: application/json" \
    -H "X-FAP-Webhook-Secret: ${FAP_WEBHOOK_SECRET}" \
    -o "$out_file" \
    -w '%{http_code}' \
    "${FAP_URL%/}/v1/fap/webhook/lnbits" \
    -d "{\"checking_id\":\"${checking_id}\",\"payment_hash\":\"${payment_hash}\",\"paid\":true}" || true)"
  rm -f "$out_file"
  if [ "$code" != "204" ] && [ "$code" != "200" ]; then
    fail "deterministic webhook fallback failed (code=${code})"
  fi
  log "PASS: settlement webhook fallback accepted (code=${code})"
}

need_cmd docker
need_cmd curl
[ "${WAIT_SECONDS}" -gt 0 ] || fail "WAIT_SECONDS must be > 0"
[ "${AMOUNT_MSAT}" -gt 0 ] || fail "AMOUNT_MSAT must be > 0"

device_cookie_jar="$(mktemp)"
cleanup() {
  rm -f "$device_cookie_jar"
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  fail "jq or python3 is required"
fi

LNBITS_INVOICE_KEY="$(read_secret_value LNBITS_INVOICE_KEY LNBITS_INVOICE_KEY_FILE "${ROOT_DIR}/secrets/lnbits_invoice_key")"
LNBITS_READ_KEY="$(read_secret_value LNBITS_READ_KEY LNBITS_READ_KEY_FILE "${ROOT_DIR}/secrets/lnbits_read_key")"
LNBITS_PAYER_ADMIN_KEY="$(read_secret_value LNBITS_PAYER_ADMIN_KEY LNBITS_PAYER_ADMIN_KEY_FILE "${ROOT_DIR}/secrets/lnbits_payer_admin_key")"
FAP_WEBHOOK_SECRET="${FAP_WEBHOOK_SECRET:-$(read_env_file_value "${ROOT_DIR}/env/fap.env" "FAP_WEBHOOK_SECRET")}"

# Backward-compatible aliases supported (legacy env names).
if [ -z "$LNBITS_INVOICE_KEY" ]; then
  LNBITS_INVOICE_KEY="${FAP_LNBITS_INVOICE_API_KEY:-}"
fi
if [ -z "$LNBITS_READ_KEY" ]; then
  LNBITS_READ_KEY="${FAP_LNBITS_READONLY_API_KEY:-}"
fi

[ -n "$LNBITS_INVOICE_KEY" ] || {
  if [ "$SKIP_MANUAL" = "1" ]; then
    skip "LNbits invoice key missing and SKIP_MANUAL=1"
  fi
  fail "missing LNbits invoice key (set LNBITS_INVOICE_KEY or FAP_LNBITS_INVOICE_API_KEY)"
}
[ -n "$LNBITS_READ_KEY" ] || {
  if [ "$SKIP_MANUAL" = "1" ]; then
    skip "LNbits read key missing and SKIP_MANUAL=1"
  fi
  fail "missing LNbits read key (set LNBITS_READ_KEY or FAP_LNBITS_READONLY_API_KEY)"
}

if [ "$MANUAL_WAIT" -eq 0 ] && [ -z "$LNBITS_PAYER_ADMIN_KEY" ]; then
  if [ "$SKIP_MANUAL" = "1" ]; then
    skip "LNBITS_PAYER_ADMIN_KEY missing and SKIP_MANUAL=1"
  fi
  log "No LNBITS_PAYER_ADMIN_KEY found; switching to --wait-manual mode"
  MANUAL_WAIT=1
fi
if [ "$MANUAL_WAIT" -eq 1 ] && [ -z "$FORCE_WEBHOOK_ON_TIMEOUT_SET" ]; then
  FORCE_WEBHOOK_ON_TIMEOUT=0
fi

log "Starting compose stack"
compose up -d --build

wait_http_200 "audistro-catalog /healthz" "${CATALOG_URL%/}/healthz"
wait_http_200 "audistro-fap /healthz" "${FAP_URL%/}/healthz"
wait_http_200 "lnbits /" "${LNBITS_BASE_URL%/}/"

CATALOG_CID="$(service_cid audistro-catalog)"
FAP_CID="$(service_cid audistro-fap)"
LNBITS_CID="$(service_cid lnbits)"
log "Resolved containers: audistro-catalog=${CATALOG_CID} audistro-fap=${FAP_CID} lnbits=${LNBITS_CID}"

AUDICATALOG_DB_PATH="$(read_env_file_value "${ROOT_DIR}/env/audistro-catalog.env" "AUDICATALOG_DB_PATH")"
if [ -z "$AUDICATALOG_DB_PATH" ]; then
  AUDICATALOG_DB_PATH="$(exec_in "$CATALOG_CID" 'printenv AUDICATALOG_DB_PATH' || true)"
fi
[ -n "$AUDICATALOG_DB_PATH" ] || fail "AUDICATALOG_DB_PATH is empty"

exec_in "$CATALOG_CID" 'command -v sqlite3 >/dev/null 2>&1' || fail "sqlite3 missing in audistro-catalog container"

log "Creating FAP payee with LNbits keys"
fap_payee_create_payload="$(cat <<JSON
{"display_name":"Paid Smoke ${ASSET_ID}","lnbits_base_url":"${FAP_LNBITS_BASE_URL}","lnbits_invoice_key":"${LNBITS_INVOICE_KEY}","lnbits_read_key":"${LNBITS_READ_KEY}"}
JSON
)"
mapfile -t payee_create_result < <(post_json POST "${FAP_URL%/}/v1/payees" "$fap_payee_create_payload")
payee_create_code="${payee_create_result[0]}"
payee_create_body="${payee_create_result[1]}"
[ "$payee_create_code" = "200" ] || fail "POST /v1/payees failed (code=${payee_create_code}): ${payee_create_body}"
created_fap_payee_id="$(json_get '.payee_id' "$payee_create_body")"
[ -n "$created_fap_payee_id" ] && [ "$created_fap_payee_id" != "null" ] || fail "missing payee_id in FAP /v1/payees response"

effective_fap_payee_id="${FAP_PAYEE_ID:-$created_fap_payee_id}"
if [ "$effective_fap_payee_id" != "$created_fap_payee_id" ]; then
  log "Using overridden FAP_PAYEE_ID=${effective_fap_payee_id} (created=${created_fap_payee_id})"
fi

now="$(date +%s)"
artist_pubkey_hex="031111111111111111111111111111111111111111111111111111111111111111"
artist_id_esc="$(sql_escape "$ARTIST_ID")"
artist_handle_esc="$(sql_escape "$ARTIST_HANDLE")"
catalog_payee_id_esc="$(sql_escape "$CATALOG_PAYEE_ID")"
asset_id_esc="$(sql_escape "$ASSET_ID")"
fap_public_base_esc="$(sql_escape "$FAP_PUBLIC_BASE_URL")"
fap_payee_id_esc="$(sql_escape "$effective_fap_payee_id")"

log "Seeding audistro-catalog artist/payee/asset for ASSET_ID=${ASSET_ID}"
docker exec -i "$CATALOG_CID" sh -lc "sqlite3 \"$AUDICATALOG_DB_PATH\"" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT OR REPLACE INTO artists (
  artist_id, pubkey_hex, handle, display_name, bio, avatar_url, created_at, updated_at
) VALUES (
  '${artist_id_esc}', '${artist_pubkey_hex}', '${artist_handle_esc}', 'Paid Smoke Artist', '', '', ${now}, ${now}
);

INSERT OR REPLACE INTO payees (
  payee_id, artist_id, fap_public_base_url, fap_payee_id, created_at, updated_at
) VALUES (
  '${catalog_payee_id_esc}', '${artist_id_esc}', '${fap_public_base_esc}', '${fap_payee_id_esc}', ${now}, ${now}
);

INSERT OR REPLACE INTO assets (
  asset_id, artist_id, payee_id, title, duration_ms, content_id, hls_master_url, preview_hls_url, price_msat, created_at, updated_at
) VALUES (
  '${asset_id_esc}', '${artist_id_esc}', '${catalog_payee_id_esc}', 'Paid Smoke Asset', 8000, 'cid-${asset_id_esc}',
  'http://localhost:18082/assets/${asset_id_esc}/master.m3u8',
  'http://localhost:18082/assets/${asset_id_esc}/master.m3u8',
  ${AMOUNT_MSAT}, ${now}, ${now}
);
COMMIT;
SQL

log "Fetching playback to verify catalog pay hints"
playback_file="$(mktemp)"
playback_code="$(curl -sS -o "$playback_file" -w '%{http_code}' "${CATALOG_URL%/}/v1/playback/${ASSET_ID}" || true)"
playback_body="$(cat "$playback_file")"
rm -f "$playback_file"
[ "$playback_code" = "200" ] || fail "GET /v1/playback/${ASSET_ID} expected 200, got ${playback_code}: ${playback_body}"

challenge_payee_id="$(json_get '.asset.pay.fap_payee_id' "$playback_body")"
challenge_fap_url="$(json_get '.asset.pay.fap_url' "$playback_body")"
[ -n "$challenge_payee_id" ] && [ "$challenge_payee_id" != "null" ] || fail "playback missing asset.pay.fap_payee_id"
[ -n "$challenge_fap_url" ] && [ "$challenge_fap_url" != "null" ] || fail "playback missing asset.pay.fap_url"
[ "$challenge_payee_id" = "$effective_fap_payee_id" ] || fail "catalog payee mismatch: playback=${challenge_payee_id}, expected=${effective_fap_payee_id}"

idempotency_key="smoke-paid-access-$(date +%s)-$RANDOM"
challenge_payload="$(cat <<JSON
{"asset_id":"${ASSET_ID}","payee_id":"${challenge_payee_id}","amount_msat":${AMOUNT_MSAT},"memo":"smoke paid access","idempotency_key":"${idempotency_key}"}
JSON
)"
log "Creating access challenge"
challenge_resp_file="$(mktemp)"
challenge_code="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -c "$device_cookie_jar" \
  -b "$device_cookie_jar" \
  -o "$challenge_resp_file" \
  -w '%{http_code}' \
  "${FAP_URL%/}/v1/fap/challenge" \
  -d "$challenge_payload" || true)"
challenge_body="$(cat "$challenge_resp_file")"
rm -f "$challenge_resp_file"
[ "$challenge_code" = "200" ] || fail "POST /v1/fap/challenge failed (code=${challenge_code}): ${challenge_body}"
grep -q "fap_device_id" "$device_cookie_jar" || fail "challenge response did not set fap_device_id cookie"

challenge_id="$(json_get '.challenge_id' "$challenge_body")"
bolt11="$(json_get '.bolt11' "$challenge_body")"
checking_id="$(json_get '.checking_id' "$challenge_body")"
payment_hash="$(json_get '.payment_hash' "$challenge_body")"
[ -n "$challenge_id" ] && [ "$challenge_id" != "null" ] || fail "challenge_id missing in challenge response"
[ -n "$bolt11" ] && [ "$bolt11" != "null" ] || fail "bolt11 missing in challenge response"

if [ "$MANUAL_WAIT" -eq 1 ]; then
  log "Manual mode enabled."
  log "Pay this invoice externally, then the script will continue polling:"
  printf '%s\n' "$bolt11"
  print_invoice_qr "$bolt11"
else
  log "Paying invoice via LNbits payer wallet API"
  pay_invoice_auto "$bolt11"
fi

log "Waiting for settlement and token exchange"
token=""
token_started_at="$SECONDS"
webhook_fallback_done=0
poll_count=0
deadline=$((SECONDS + WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  poll_count=$((poll_count + 1))
  token_resp_file="$(mktemp)"
  token_code="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -c "$device_cookie_jar" \
    -b "$device_cookie_jar" \
    -o "$token_resp_file" \
    -w '%{http_code}' \
    "${FAP_URL%/}/v1/fap/token" \
    -d "{\"challenge_id\":\"${challenge_id}\"}" || true)"
  token_body="$(cat "$token_resp_file")"
  rm -f "$token_resp_file"

  if [ "$token_code" = "200" ]; then
    token="$(json_get '.token' "$token_body")"
    [ -n "$token" ] && [ "$token" != "null" ] || fail "token missing in /v1/fap/token success response"
    log "PASS: token issued for challenge_id=${challenge_id}"
    break
  fi

  if [ "$token_code" != "409" ]; then
    fail "POST /v1/fap/token unexpected code=${token_code}: ${token_body}"
  fi

  if [ "$poll_count" -eq 1 ] || [ $((poll_count % 5)) -eq 0 ]; then
    log "pending: token not issued yet (challenge_id=${challenge_id}, waited=$((SECONDS - token_started_at))s)"
  fi

  if [ "$webhook_fallback_done" -eq 0 ]; then
    if lnbits_check_payment_paid "$checking_id" || lnbits_check_payment_paid "$payment_hash"; then
      log "LNbits reports invoice as paid; notifying FAP webhook for deterministic settlement"
      trigger_settlement_webhook "$checking_id" "$payment_hash"
      webhook_fallback_done=1
      sleep 1
      continue
    fi
  fi

  if [ "$FORCE_WEBHOOK_ON_TIMEOUT" = "1" ] \
    && [ "$webhook_fallback_done" -eq 0 ] \
    && [ $((SECONDS - token_started_at)) -ge "$SETTLEMENT_GRACE_SECONDS" ] \
    && { [ -n "${checking_id}" ] && [ "${checking_id}" != "null" ] || [ -n "${payment_hash}" ] && [ "${payment_hash}" != "null" ]; }; then
    log "No settlement observed yet; triggering deterministic webhook fallback"
    trigger_settlement_webhook "$checking_id" "$payment_hash"
    webhook_fallback_done=1
  fi

  sleep "$WAIT_INTERVAL_SECONDS"
done

[ -n "$token" ] || fail "timed out waiting for settled challenge/token issuance"

key_bin="$(mktemp)"
key_code="$(curl -sS -o "$key_bin" -w '%{http_code}' -H "Authorization: Bearer ${token}" -b "$device_cookie_jar" "${FAP_URL%/}/hls/${ASSET_ID}/key" || true)"
[ "$key_code" = "200" ] || {
  rm -f "$key_bin"
  fail "GET /hls/${ASSET_ID}/key expected 200, got ${key_code}"
}
key_len="$(wc -c < "$key_bin" | tr -d '[:space:]')"
rm -f "$key_bin"
[ "$key_len" = "16" ] || fail "GET /hls/${ASSET_ID}/key expected 16 bytes, got ${key_len}"

log "PASS: non-dev paid access smoke succeeded for asset=${ASSET_ID} challenge_id=${challenge_id}"
