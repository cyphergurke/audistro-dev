#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FAP_BASE_URL="${FAP_BASE_URL:-http://localhost:18081}"
ASSET_ID="${ASSET_ID:-asset1}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-120}"

log() {
  printf '[fap-step1] %s\n' "$*"
}

fail() {
  printf '[fap-step1] FAIL: %s\n' "$*" >&2
  exit 1
}

tcp_open() {
  exec 3<>/dev/tcp/127.0.0.1/18081 2>/dev/null || return 1
  exec 3<&-
  exec 3>&-
  return 0
}

extract_json_field() {
  local field="$1"
  local payload="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r ".$field"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload" | python3 - "$field" <<'PY'
import json
import sys
field = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(field, "")
if value is None:
    value = ""
print(value)
PY
    return 0
  fi
  printf '%s' "$payload" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

cleanup_files=()
cleanup() {
  if [ "${#cleanup_files[@]}" -gt 0 ]; then
    rm -f "${cleanup_files[@]}"
  fi
}
trap cleanup EXIT

log "Starting compose stack"
docker compose up -d --build

log "Waiting for FAP readiness at ${FAP_BASE_URL}/healthz"
deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while :; do
  health_code="$(curl -sS -o /dev/null -w '%{http_code}' "${FAP_BASE_URL}/healthz" || true)"
  if [ "$health_code" = "200" ]; then
    break
  fi
  if [ "$health_code" = "404" ] || [ "$health_code" = "405" ]; then
    if tcp_open; then
      break
    fi
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "FAP did not become reachable within ${WAIT_TIMEOUT_SECONDS}s (last health code=${health_code})"
  fi
  sleep 1
done
log "PASS: FAP is reachable"

access_body_file="$(mktemp)"
cleanup_files+=("$access_body_file")
access_code="$(curl -sS -o "$access_body_file" -w '%{http_code}' -X POST "${FAP_BASE_URL}/v1/access/${ASSET_ID}" || true)"
access_body="$(cat "$access_body_file")"
if [ "$access_code" != "200" ]; then
  fail "POST /v1/access/${ASSET_ID} expected 200, got ${access_code}. body=${access_body}"
fi

access_token="$(extract_json_field "access_token" "$access_body")"
expires_at="$(extract_json_field "expires_at" "$access_body")"
if [ -z "${access_token}" ] || [ "${access_token}" = "null" ]; then
  fail "POST /v1/access/${ASSET_ID} did not return access_token. body=${access_body}"
fi
if [ -z "${expires_at}" ] || [ "${expires_at}" = "null" ]; then
  fail "POST /v1/access/${ASSET_ID} did not return expires_at. body=${access_body}"
fi
log "PASS: POST /v1/access/${ASSET_ID} returned token and expiry"

key_body_file="$(mktemp)"
cleanup_files+=("$key_body_file")
key_code="$(curl -sS -o "$key_body_file" -w '%{http_code}' -H "Authorization: Bearer ${access_token}" "${FAP_BASE_URL}/hls/${ASSET_ID}/key" || true)"
key_len="$(wc -c < "$key_body_file" | tr -d '[:space:]')"
if [ "$key_code" != "200" ]; then
  fail "GET /hls/${ASSET_ID}/key with valid token expected 200, got ${key_code}"
fi
if [ "$key_len" != "16" ]; then
  fail "GET /hls/${ASSET_ID}/key expected 16 bytes, got ${key_len}"
fi
log "PASS: GET /hls/${ASSET_ID}/key with valid token returned 16 bytes"

missing_body_file="$(mktemp)"
cleanup_files+=("$missing_body_file")
missing_code="$(curl -sS -o "$missing_body_file" -w '%{http_code}' "${FAP_BASE_URL}/hls/${ASSET_ID}/key" || true)"
if [ "$missing_code" != "401" ]; then
  fail "GET /hls/${ASSET_ID}/key without token expected 401, got ${missing_code}"
fi
log "PASS: GET /hls/${ASSET_ID}/key without token returned 401"

invalid_body_file="$(mktemp)"
cleanup_files+=("$invalid_body_file")
invalid_code="$(curl -sS -o "$invalid_body_file" -w '%{http_code}' -H "Authorization: Bearer invalid-token" "${FAP_BASE_URL}/hls/${ASSET_ID}/key" || true)"
if [ "$invalid_code" != "401" ]; then
  fail "GET /hls/${ASSET_ID}/key with invalid token expected 401, got ${invalid_code}"
fi
log "PASS: GET /hls/${ASSET_ID}/key with invalid token returned 401"

log "PASS: FAP Step 1 smoke test complete"
