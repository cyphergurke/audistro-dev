#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CI_MODE="${CI:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-0}"

ASSET_ID="${ASSET_ID:-asset_smoke_upload_encrypt_pay}"
DEFAULT_WAIT_SECONDS=240
if [ "$CI_MODE" = "1" ]; then
  DEFAULT_WAIT_SECONDS=180
fi
WAIT_SECONDS="${WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}"
FAP_PUBLIC_BASE_URL="${FAP_PUBLIC_BASE_URL:-http://localhost:18081}"
CATALOG_BASE_URL="${CATALOG_BASE_URL:-http://localhost:18080}"
WEB_BASE_URL="${WEB_BASE_URL:-http://localhost:3000}"
PROVIDER_EU_1_URL="${PROVIDER_EU_1_URL:-http://localhost:18082}"
PROVIDER_EU_2_URL="${PROVIDER_EU_2_URL:-http://localhost:18083}"
PROVIDER_US_1_URL="${PROVIDER_US_1_URL:-http://localhost:18084}"
SETUP_SCRIPT="${SETUP_SCRIPT:-./scripts/smoke-upload-encrypt-pay.sh}"
DUMMY_TOKEN="${DUMMY_TOKEN:-abcdefghijklmnopqrstuvwxyz123456}"
SETUP_IF_MISSING="${SETUP_IF_MISSING:-1}"

PROVIDER_EU_1_SERVICE="audistro-provider_eu_1"
PROVIDER_EU_2_SERVICE="audistro-provider_eu_2"
PROVIDER_US_1_SERVICE="audistro-provider_us_1"
MANUAL_WAIT=0
for arg in "$@"; do
  case "$arg" in
    --wait-manual)
      MANUAL_WAIT=1
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./scripts/smoke-encrypted-failover.sh [--wait-manual]

Flow:
  1. ensure an encrypted asset exists (reuse current asset or run setup smoke)
  2. assert the asset is already present on eu_1 and eu_2
  3. trigger rescan/announce for eu_1 and eu_2
  4. inject a segment failure into playback provider[0]
  5. assert provider[0] segment fetch fails and provider[1] succeeds
  6. assert web /api/playlist rewrites EXT-X-KEY to /api/hls-key and keeps fallback-ready provider ordering

Env overrides:
  ASSET_ID
  WAIT_SECONDS
  FAP_PUBLIC_BASE_URL
  CATALOG_BASE_URL
  WEB_BASE_URL
  PROVIDER_EU_1_URL
  PROVIDER_EU_2_URL
  PROVIDER_US_1_URL
  SETUP_SCRIPT
  SETUP_IF_MISSING
  DUMMY_TOKEN
USAGE
      exit 0
      ;;
    *)
      printf '[smoke-encrypted-failover] FAIL: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[smoke-encrypted-failover] %s\n' "$*"
}

fail() {
  printf '[smoke-encrypted-failover] FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf '[smoke-encrypted-failover] SKIP: %s\n' "$*"
  exit 0
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

compose() {
  docker compose "$@"
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

service_cid() {
  local service="$1"
  local cid
  cid="$(compose ps -q "$service" | head -n1)"
  [ -n "$cid" ] || fail "container not found for service: $service"
  printf '%s' "$cid"
}

exec_in() {
  local cid="$1"
  shift
  docker exec -i "$cid" sh -lc "$*"
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

playback_provider_lines() {
  local payload="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r '.providers[]? | "\(.provider_id)|\(.base_url)"'
    return 0
  fi
  JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ["JSON_PAYLOAD"])
for provider in payload.get("providers") or []:
    print(f"{provider.get('provider_id','')}|{provider.get('base_url','')}")
PY
}

playback_provider_count() {
  local payload="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq '.providers | length'
    return 0
  fi
  JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ["JSON_PAYLOAD"])
print(len(payload.get("providers") or []))
PY
}

resolve_playlist_url() {
  local provider_base_url="$1"
  local asset_id="$2"
  local trimmed="${provider_base_url%/}"
  if [[ "$trimmed" == */assets/${asset_id} ]]; then
    printf '%s/master.m3u8' "$trimmed"
  else
    printf '%s/assets/%s/master.m3u8' "$trimmed" "$asset_id"
  fi
}

first_media_ref_from_playlist() {
  local playlist_file="$1"
  awk '/^[^#[:space:]]/ {print; exit}' "$playlist_file"
}

ref_to_absolute_url() {
  local playlist_url="$1"
  local ref="$2"
  case "$ref" in
    http://*|https://*)
      printf '%s' "$ref"
      ;;
    /*)
      printf '%s' "$(printf '%s' "$playlist_url" | sed -E 's#(https?://[^/]+).*#\1#')${ref}"
      ;;
    *)
      printf '%s/%s' "${playlist_url%/*}" "$ref"
      ;;
  esac
}

trigger_rescan_announce() {
  local provider_cid="$1"
  local asset_id="$2"
  exec_in "$provider_cid" 'curl -fsS -X POST http://127.0.0.1:8080/internal/rescan >/dev/null'
  exec_in "$provider_cid" "curl -fsS -H 'Content-Type: application/json' -d '{\"asset_id\":\"${asset_id}\"}' http://127.0.0.1:8080/internal/announce >/dev/null"
}

inject_broken_segment() {
  local provider_cid="$1"
  local data_path="$2"
  local asset_id="$3"
  local master_file
  master_file="$(mktemp)"
  docker exec "$provider_cid" sh -lc "cat '${data_path}/assets/${asset_id}/master.m3u8'" >"$master_file"
  local seg_ref
  seg_ref="$(first_media_ref_from_playlist "$master_file")"
  rm -f "$master_file"
  [ -n "$seg_ref" ] || fail "playlist has no segment reference to break"
  local seg_name
  seg_name="$(basename "$seg_ref")"
  exec_in "$provider_cid" "rm -f '${data_path}/assets/${asset_id}/${seg_name}'"
  log "Injected deterministic failure: removed ${seg_name}"
}

assert_public_provider_behavior() {
  local provider_base="$1"
  local expected_segment="$2"
  local playlist_url
  playlist_url="$(resolve_playlist_url "$provider_base" "$ASSET_ID")"
  local playlist_file
  playlist_file="$(mktemp)"
  local playlist_code
  playlist_code="$(curl -sS -o "$playlist_file" -w '%{http_code}' "$playlist_url" || true)"
  [ "$playlist_code" = "200" ] || fail "provider playlist expected 200 at ${playlist_url}, got ${playlist_code}"
  grep -q '#EXT-X-KEY:METHOD=AES-128' "$playlist_file" || fail "public playlist missing AES-128 key line: ${playlist_url}"
  grep -q "URI=\"${FAP_PUBLIC_BASE_URL%/}/hls/${ASSET_ID}/key\"" "$playlist_file" || fail "public playlist missing FAP key URI: ${playlist_url}"
  local seg_ref
  seg_ref="$(first_media_ref_from_playlist "$playlist_file")"
  [ -n "$seg_ref" ] || fail "provider playlist has no media segment: ${playlist_url}"
  local seg_url
  seg_url="$(ref_to_absolute_url "$playlist_url" "$seg_ref")"
  local seg_code
  seg_code="$(curl -sS -o /dev/null -w '%{http_code}' "$seg_url" || true)"
  rm -f "$playlist_file"
  if [ "$expected_segment" = "200" ]; then
    [ "$seg_code" = "200" ] || fail "segment expected 200 at ${seg_url}, got ${seg_code}"
  else
    [ "$seg_code" != "200" ] || fail "segment expected non-200 at ${seg_url}, got 200"
  fi
  log "PASS: public provider check ${provider_base} segment=${seg_code}"
}

assert_web_playlist_behavior() {
  local provider_id="$1"
  local expected_segment="$2"
  local playlist_url="${WEB_BASE_URL%/}/api/playlist/${ASSET_ID}?providerId=${provider_id}&token=${DUMMY_TOKEN}"
  local playlist_file
  playlist_file="$(mktemp)"
  local playlist_code
  playlist_code="$(curl -sS -o "$playlist_file" -w '%{http_code}' "$playlist_url" || true)"
  [ "$playlist_code" = "200" ] || fail "web playlist expected 200 at ${playlist_url}, got ${playlist_code}"
  grep -q '#EXT-X-KEY:METHOD=AES-128' "$playlist_file" || fail "web playlist missing AES-128 key line: ${playlist_url}"
  grep -q "URI=\"/api/hls-key/${ASSET_ID}?token=${DUMMY_TOKEN}\"" "$playlist_file" || fail "web playlist missing same-origin key proxy URI: ${playlist_url}"
  local seg_ref
  seg_ref="$(first_media_ref_from_playlist "$playlist_file")"
  [ -n "$seg_ref" ] || fail "web playlist has no media segment: ${playlist_url}"
  local seg_url
  seg_url="$(ref_to_absolute_url "$playlist_url" "$seg_ref")"
  local seg_code
  seg_code="$(curl -sS -o /dev/null -w '%{http_code}' "$seg_url" || true)"
  rm -f "$playlist_file"
  if [ "$expected_segment" = "200" ]; then
    [ "$seg_code" = "200" ] || fail "web-referenced segment expected 200 at ${seg_url}, got ${seg_code}"
  else
    [ "$seg_code" != "200" ] || fail "web-referenced segment expected non-200 at ${seg_url}, got 200"
  fi
  log "PASS: web playlist check provider=${provider_id} segment=${seg_code}"
}

need_cmd docker
need_cmd curl
need_cmd python3

log "Starting compose stack"
compose up -d --build
wait_http_200 "audistro-catalog /healthz" "${CATALOG_BASE_URL%/}/healthz"
wait_http_200 "audistro-fap /healthz" "${FAP_PUBLIC_BASE_URL%/}/healthz"
wait_http_200 "${PROVIDER_EU_1_SERVICE} /readyz" "${PROVIDER_EU_1_URL%/}/readyz"
wait_http_200 "${PROVIDER_EU_2_SERVICE} /readyz" "${PROVIDER_EU_2_URL%/}/readyz"
wait_http_200 "web /" "${WEB_BASE_URL%/}"

CATALOG_CID="$(service_cid audistro-catalog)"
PROVIDER_EU_1_CID="$(service_cid ${PROVIDER_EU_1_SERVICE})"
PROVIDER_EU_2_CID="$(service_cid ${PROVIDER_EU_2_SERVICE})"
PROVIDER_DATA_PATH="$(read_env_file_value "${ROOT_DIR}/env/audistro-provider_eu_1.env" "PROVIDER_DATA_PATH")"
[ -n "$PROVIDER_DATA_PATH" ] || fail "PROVIDER_DATA_PATH is empty"

if ! curl -fsS "${PROVIDER_EU_1_URL%/}/assets/${ASSET_ID}/master.m3u8" >/dev/null 2>&1; then
  [ "$SETUP_IF_MISSING" = "1" ] || fail "encrypted asset ${ASSET_ID} missing on eu_1 and setup disabled"
  if [ "$SKIP_MANUAL" = "1" ] && [ -z "${LNBITS_PAYER_ADMIN_KEY:-}" ] && [ "$MANUAL_WAIT" != "1" ]; then
    skip "encrypted asset missing and setup would require payment, but SKIP_MANUAL=1"
  fi
  log "Encrypted asset missing; running setup smoke"
  if [ "$MANUAL_WAIT" = "1" ]; then
    ASSET_ID="$ASSET_ID" "$SETUP_SCRIPT" --wait-manual
  else
    ASSET_ID="$ASSET_ID" "$SETUP_SCRIPT"
  fi
fi

curl -fsS "${PROVIDER_EU_1_URL%/}/assets/${ASSET_ID}/master.m3u8" >/dev/null || fail "encrypted asset still missing on eu_1 after setup"
curl -fsS "${PROVIDER_EU_2_URL%/}/assets/${ASSET_ID}/master.m3u8" >/dev/null || fail "encrypted asset missing on eu_2; fanout publish is not working"
log "PASS: encrypted asset present on eu_1 and eu_2"

log "Triggering provider rescan/announce"
trigger_rescan_announce "$PROVIDER_EU_1_CID" "$ASSET_ID"
trigger_rescan_announce "$PROVIDER_EU_2_CID" "$ASSET_ID"

provider_eu_1_health="$(curl -fsS "${PROVIDER_EU_1_URL%/}/healthz")"
provider_eu_2_health="$(curl -fsS "${PROVIDER_EU_2_URL%/}/healthz")"
provider_eu_1_id="$(json_get '.provider_id' "$provider_eu_1_health")"
provider_eu_2_id="$(json_get '.provider_id' "$provider_eu_2_health")"

playback_file="$(mktemp)"
playback_code="$(curl -sS -o "$playback_file" -w '%{http_code}' "${CATALOG_BASE_URL%/}/v1/playback/${ASSET_ID}" || true)"
playback_json="$(cat "$playback_file")"
rm -f "$playback_file"
[ "$playback_code" = "200" ] || fail "GET /v1/playback/${ASSET_ID} failed (code=${playback_code}): ${playback_json}"

providers_count="$(playback_provider_count "$playback_json")"
[ "$providers_count" -ge 2 ] || fail "expected >=2 providers in playback after real fanout publish, got ${providers_count}"

mapfile -t provider_lines < <(playback_provider_lines "$playback_json")
[ "${#provider_lines[@]}" -ge 2 ] || fail "provider parse returned <2 lines"
first_provider_id="$(printf '%s' "${provider_lines[0]}" | cut -d'|' -f1)"
first_provider_base="$(printf '%s' "${provider_lines[0]}" | cut -d'|' -f2)"
second_provider_id="$(printf '%s' "${provider_lines[1]}" | cut -d'|' -f1)"
second_provider_base="$(printf '%s' "${provider_lines[1]}" | cut -d'|' -f2)"
log "Playback order: #1=${first_provider_id} ${first_provider_base} | #2=${second_provider_id} ${second_provider_base}"

case "$first_provider_base" in
  ${PROVIDER_EU_1_URL}/assets/${ASSET_ID})
    inject_broken_segment "$PROVIDER_EU_1_CID" "$PROVIDER_DATA_PATH" "$ASSET_ID"
    ;;
  ${PROVIDER_EU_2_URL}/assets/${ASSET_ID})
    inject_broken_segment "$PROVIDER_EU_2_CID" "$PROVIDER_DATA_PATH" "$ASSET_ID"
    ;;
  *)
    fail "provider[0] is not eu_1 or eu_2: ${first_provider_base}"
    ;;
esac

assert_public_provider_behavior "$first_provider_base" "non200"
assert_public_provider_behavior "$second_provider_base" "200"
assert_web_playlist_behavior "$first_provider_id" "non200"
assert_web_playlist_behavior "$second_provider_id" "200"

log "PASS: encrypted failover tested with real multi-provider publish for asset=${ASSET_ID}"
