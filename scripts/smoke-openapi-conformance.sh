#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CI_MODE="${CI:-0}"
SKIP_BOOT="${SKIP_BOOT:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-0}"

CATALOG_URL="${CATALOG_URL:-http://localhost:18080}"
FAP_URL="${FAP_URL:-http://localhost:18081}"
PROVIDER_URL="${PROVIDER_URL:-http://localhost:18082}"
ASSET_ID="${ASSET_ID:-asset1}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/openapi-conformance.cookies}"
DEFAULT_WAIT_SECONDS=120
if [ "$CI_MODE" = "1" ]; then
  DEFAULT_WAIT_SECONDS=90
fi
WAIT_SECONDS="${WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-2}"
LNBITS_BASE_URL="${LNBITS_BASE_URL:-http://localhost:18090}"

log() {
  printf '[smoke-openapi-conformance] %s\n' "$*"
}

fail() {
  printf '[smoke-openapi-conformance] FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf '[smoke-openapi-conformance] SKIP: %s\n' "$*"
  exit 0
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

compose() {
  docker compose "$@"
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
if field.startswith("."):
    field = field[1:]
value = obj
for part in [p for p in field.split(".") if p]:
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

ensure_stack() {
  if [ "$SKIP_BOOT" = "1" ]; then
    log "SKIP_BOOT=1, assuming compose stack is already running"
  else
    log "Booting compose stack"
    compose up -d --build audistro-catalog audistro-fap audistro-provider_eu_1 audistro-web
  fi
  wait_http_200 "audistro-catalog /healthz" "${CATALOG_URL%/}/healthz"
  wait_http_200 "audistro-fap /healthz" "${FAP_URL%/}/healthz"
  wait_http_200 "audistro-provider /readyz" "${PROVIDER_URL%/}/readyz"
}

ensure_seeded_asset() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${CATALOG_URL%/}/v1/playback/${ASSET_ID}" || true)"
  if [ "$code" = "200" ]; then
    log "PASS: seeded asset available for playback ASSET_ID=${ASSET_ID}"
    return 0
  fi
  log "Playback asset ${ASSET_ID} missing; seeding via smoke-e2e-playback.sh"
  ASSET_ID="$ASSET_ID" ./scripts/smoke-e2e-playback.sh
}

extract_cookie_header() {
  local jar="$1"
  awk 'BEGIN{FS="\t"} $6=="fap_device_id" && $7!="" {print $6 "=" $7; exit}' "$jar"
}

run_helper() {
  local config_path="$1"
  (cd "$ROOT_DIR/tools/openapi-conformance" && go run . -config "$config_path")
}

run_core_conformance() {
  local cookie_header="$1"
  local config_file
  config_file="$(mktemp)"
  cat >"$config_file" <<JSON
{
  "checks": [
    {
      "name": "catalog openapi json reachable",
      "spec_url": "${CATALOG_URL%/}/openapi.json",
      "url": "${CATALOG_URL%/}/v1/playback/${ASSET_ID}",
      "method": "GET",
      "expected_status": 200
    },
    {
      "name": "fap device bootstrap response",
      "spec_url": "${FAP_URL%/}/openapi.json",
      "url": "${FAP_URL%/}/v1/device/bootstrap",
      "method": "POST",
      "expected_status": 200
    },
    {
      "name": "fap ledger unauthorized without cookie",
      "spec_url": "${FAP_URL%/}/openapi.json",
      "url": "${FAP_URL%/}/v1/ledger",
      "method": "GET",
      "expected_status": 401
    },
    {
      "name": "fap ledger authorized with cookie",
      "spec_url": "${FAP_URL%/}/openapi.json",
      "url": "${FAP_URL%/}/v1/ledger?limit=20",
      "method": "GET",
      "expected_status": 200,
      "headers": {
        "Cookie": "${cookie_header}"
      }
    },
    {
      "name": "provider healthz response",
      "spec_url": "${PROVIDER_URL%/}/openapi.json",
      "url": "${PROVIDER_URL%/}/healthz",
      "method": "GET",
      "expected_status": 200
    },
    {
      "name": "provider readyz response",
      "spec_url": "${PROVIDER_URL%/}/openapi.json",
      "url": "${PROVIDER_URL%/}/readyz",
      "method": "GET",
      "expected_status": 200
    }
  ]
}
JSON
  run_helper "$config_file"
  rm -f "$config_file"
}

run_optional_paid_conformance() {
  if [ "${SKIP_MANUAL}" = "1" ]; then
    log "SKIP: optional paid-path conformance skipped because SKIP_MANUAL=1"
    return 0
  fi
  local payer_key
  payer_key="${LNBITS_PAYER_ADMIN_KEY:-}"
  if [ -z "$payer_key" ] && [ -f "$ROOT_DIR/secrets/lnbits_payer_admin_key" ]; then
    payer_key="$(tr -d '\r\n' < "$ROOT_DIR/secrets/lnbits_payer_admin_key")"
  fi
  local invoice_key
  invoice_key="${LNBITS_INVOICE_KEY:-${FAP_LNBITS_INVOICE_API_KEY:-}}"
  if [ -z "$invoice_key" ] && [ -f "$ROOT_DIR/secrets/lnbits_invoice_key" ]; then
    invoice_key="$(tr -d '\r\n' < "$ROOT_DIR/secrets/lnbits_invoice_key")"
  fi
  local read_key
  read_key="${LNBITS_READ_KEY:-${FAP_LNBITS_READONLY_API_KEY:-}}"
  if [ -z "$read_key" ] && [ -f "$ROOT_DIR/secrets/lnbits_read_key" ]; then
    read_key="$(tr -d '\r\n' < "$ROOT_DIR/secrets/lnbits_read_key")"
  fi

  if [ -z "$payer_key" ] || [ -z "$invoice_key" ] || [ -z "$read_key" ]; then
    log "SKIP: optional paid-path conformance skipped because LNbits secrets are incomplete"
    return 0
  fi

  log "Ensuring paid smoke prerequisites"
  env \
    CI="$CI_MODE" \
    SKIP_MANUAL="$SKIP_MANUAL" \
    LNBITS_PAYER_ADMIN_KEY="$payer_key" \
    LNBITS_INVOICE_KEY="$invoice_key" \
    LNBITS_READ_KEY="$read_key" \
    ./scripts/smoke-paid-access.sh

  local paid_playback_file paid_playback_code paid_playback_json paid_payee_id
  paid_playback_file="$(mktemp)"
  paid_playback_code="$(curl -sS -o "$paid_playback_file" -w '%{http_code}' "${CATALOG_URL%/}/v1/playback/asset_paid_smoke" || true)"
  paid_playback_json="$(cat "$paid_playback_file")"
  rm -f "$paid_playback_file"
  [ "$paid_playback_code" = "200" ] || fail "paid-path playback lookup failed (code=${paid_playback_code}): ${paid_playback_json}"
  paid_payee_id="$(json_get '.asset.pay.fap_payee_id' "$paid_playback_json")"
  [ -n "$paid_payee_id" ] && [ "$paid_payee_id" != "null" ] || fail "paid-path playback missing asset.pay.fap_payee_id"

  local paid_cookie_jar="/tmp/openapi-conformance-paid.cookies"
  rm -f "$paid_cookie_jar"
  local bootstrap_code
  bootstrap_code="$(curl -sS -c "$paid_cookie_jar" -o /dev/null -w '%{http_code}' -X POST "${FAP_URL%/}/v1/device/bootstrap" || true)"
  [ "$bootstrap_code" = "200" ] || fail "paid-path device bootstrap failed (code=${bootstrap_code})"
  local paid_cookie
  paid_cookie="$(extract_cookie_header "$paid_cookie_jar")"
  [ -n "$paid_cookie" ] || fail "paid-path device cookie missing after bootstrap"

  local challenge_body_file token_body_file challenge_cfg token_cfg
  challenge_body_file="$(mktemp)"
  challenge_cfg="$(mktemp)"
  cat >"$challenge_cfg" <<JSON
{
  "checks": [
    {
      "name": "fap challenge paid-path response",
      "spec_url": "${FAP_URL%/}/openapi.json",
      "url": "${FAP_URL%/}/v1/fap/challenge",
      "method": "POST",
      "expected_status": 200,
      "capture_body_path": "${challenge_body_file}",
      "headers": {
        "Content-Type": "application/json",
        "Cookie": "${paid_cookie}"
      },
      "body": "{\"asset_id\":\"asset_paid_smoke\",\"payee_id\":\"${paid_payee_id}\",\"amount_msat\":1000000,\"memo\":\"openapi conformance\",\"idempotency_key\":\"openapi-conformance-paid\"}"
    }
  ]
}
JSON
  run_helper "$challenge_cfg"
  local challenge_payload challenge_id bolt11
  challenge_payload="$(cat "$challenge_body_file")"
  challenge_id="$(json_get '.challenge_id' "$challenge_payload")"
  bolt11="$(json_get '.bolt11' "$challenge_payload")"
  [ -n "$challenge_id" ] && [ "$challenge_id" != "null" ] || fail "challenge_id missing in optional paid-path response"
  [ -n "$bolt11" ] && [ "$bolt11" != "null" ] || fail "bolt11 missing in optional paid-path response"

  local pay_code
  pay_code="$(curl -sS -X POST \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${payer_key}" \
    -o /dev/null \
    -w '%{http_code}' \
    "${LNBITS_BASE_URL%/}/api/v1/payments" \
    -d "{\"out\":true,\"bolt11\":\"${bolt11}\"}" || true)"
  [ "$pay_code" = "201" ] || [ "$pay_code" = "200" ] || fail "optional paid-path auto-pay failed (code=${pay_code})"

  local deadline=$((SECONDS + WAIT_SECONDS))
  token_body_file="$(mktemp)"
  token_cfg="$(mktemp)"
  while :; do
    cat >"$token_cfg" <<JSON
{
  "checks": [
    {
      "name": "fap token paid-path response",
      "spec_url": "${FAP_URL%/}/openapi.json",
      "url": "${FAP_URL%/}/v1/fap/token",
      "method": "POST",
      "expected_status": 200,
      "capture_body_path": "${token_body_file}",
      "headers": {
        "Content-Type": "application/json",
        "Cookie": "${paid_cookie}"
      },
      "body": "{\"challenge_id\":\"${challenge_id}\"}"
    }
  ]
}
JSON
    if run_helper "$token_cfg" >/dev/null 2>&1; then
      log "PASS: optional paid-path challenge/token responses conform to OpenAPI"
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "timeout waiting for paid-path token conformance"
    fi
    sleep "$WAIT_INTERVAL_SECONDS"
  done

  rm -f "$challenge_body_file" "$token_body_file" "$challenge_cfg" "$token_cfg" "$paid_cookie_jar"
}

need_cmd bash
need_cmd curl
need_cmd docker
need_cmd go
need_cmd python3

rm -f "$COOKIE_JAR"
ensure_stack
ensure_seeded_asset

bootstrap_code="$(curl -sS -c "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X POST "${FAP_URL%/}/v1/device/bootstrap" || true)"
[ "$bootstrap_code" = "200" ] || fail "device bootstrap failed before ledger conformance (code=${bootstrap_code})"
cookie_header="$(extract_cookie_header "$COOKIE_JAR")"
[ -n "$cookie_header" ] || fail "device bootstrap did not yield fap_device_id cookie"

run_core_conformance "$cookie_header"
run_optional_paid_conformance

log "PASS: live OpenAPI conformance smoke succeeded"
